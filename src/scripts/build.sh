#!/usr/bin/env sh
# build.sh - Build Nix packages while caching dependencies to Attic.
# Usage: build.sh <package> [package ...]
# Example: build.sh bash coreutils gcc

set -euo pipefail

# Log messages with a consistent prefix.
log() {
    echo "[build] $*"
}

# Push store paths to attic if we have write permission.
# Falls back to individual pushes if batch push fails. Counts offered
# and failed paths so the end-of-run summary can surface silent push
# holes without changing the tolerant warn-and-continue behavior.
# Args: the store paths to push.
PUSH_OFFERED=0
PUSH_FAILED=0
push_to_attic() {
    if [ "$HAS_WRITE_PERMISSION" != true ]; then
        return 0
    fi
    PUSH_OFFERED=$((PUSH_OFFERED + $#))

    if attic push "remote:${ATTIC_CACHE}" "$@" 2>&1; then
        return 0
    fi

    # Batch push failed, try individually.
    log "WARNING: Batch push failed, retrying individually..."
    for path in "$@"; do
        attic push "remote:${ATTIC_CACHE}" "$path" 2>&1 || {
            PUSH_FAILED=$((PUSH_FAILED + 1))
            log "Failed to push: $path"
        }
    done
}

# Sign a realized closure with the mirror key and copy it into the
# local NAR mirror so the next layer-invalidated run substitutes it
# from disk instead of the network. nix copy is incremental; paths the
# mirror already holds cost a presence check, not a transfer. Signing
# touches store-DB metadata only (no NAR reads) and is idempotent.
# Mirror failures never fail the build; the next run just refills from
# attic. Args: the store paths whose closures to mirror.
mirror_closure() {
    if [ -z "$NIX_MIRROR" ]; then
        return 0
    fi
    nix store sign --key-file "$MIRROR_KEY" --recursive "$@" || {
        log "WARNING: mirror signing failed; skipping mirror copy"
        return 0
    }
    nix copy --to "file://${NIX_MIRROR}?compression=zstd" "$@" || \
        log "WARNING: mirror copy failed; next run refills from attic"
}

# Validate required environment variables.
if [ -z "${ATTIC_SERVER_URL:-}" ]; then
    log "ERROR: ATTIC_SERVER_URL environment variable is required"
    exit 1
fi
if [ -z "${ATTIC_CACHE:-}" ]; then
    log "ERROR: ATTIC_CACHE environment variable is required"
    exit 1
fi

# Try to read token from mounted secret if not in environment.
if [ -z "${ATTIC_TOKEN:-}" ] && [ -f /run/secrets/attic_token ]; then
    ATTIC_TOKEN="$(cat /run/secrets/attic_token)"
fi

# Validate we have a token from either source.
if [ -z "${ATTIC_TOKEN:-}" ]; then
    log "ERROR: No attic token found in ATTIC_TOKEN or" \
        "/run/secrets/attic_token"
    exit 1
fi

# Ensure attic is installed and working.
if command -v attic >/dev/null 2>&1 && attic --version >/dev/null 2>&1; then
    log "Attic available: $(attic --version)"
else
    log "Installing attic-client..."
    nix profile install nixpkgs#attic-client
    if ! attic --version >/dev/null 2>&1; then
        log "ERROR: attic fails to execute after installation"
        exit 1
    fi
    log "Attic OK: $(attic --version)"
fi

# Login to attic if not already logged in.
if ! attic cache info "remote:${ATTIC_CACHE}" >/dev/null 2>&1; then
    log "Logging into attic at $ATTIC_SERVER_URL..."
    if attic login remote "$ATTIC_SERVER_URL" "$ATTIC_TOKEN" 2>&1; then
        log "Login command succeeded, verifying cache access..."

        # Ensure the desired cache is accessible after login.
        if attic cache info "remote:${ATTIC_CACHE}" >/dev/null 2>&1; then
            log "Successfully logged into attic and verified access"

            # Configure Nix to use this cache as a substituter.
            log "Configuring Nix to use remote:${ATTIC_CACHE}..."
            if attic use "remote:${ATTIC_CACHE}" 2>&1; then
                log "Nix configured to use attic cache as substituter"
            else
                log "WARNING: Failed to configure Nix substituter"
            fi
        else
            log "ERROR: Login OK but cache '${ATTIC_CACHE}' not" \
                "accessible"
            exit 1
        fi
    else
        log "ERROR: Failed to login to attic"
        exit 1
    fi
else
    log "Already logged into attic"

    # Still need to configure Nix substituter if already logged in.
    log "Configuring Nix to use remote:${ATTIC_CACHE}..."
    if attic use "remote:${ATTIC_CACHE}" 2>&1; then
        log "Nix configured to use attic cache as substituter"
    else
        log "WARNING: Failed to configure Nix substituter"
    fi
fi

# Configure the local NAR mirror (BuildKit cache mount, see the
# Dockerfile). It is listed ahead of attic (priority=10) so a re-run
# after a layer invalidation refills the fresh store from local disk;
# attic still serves whatever the mirror lacks and remains the source
# of truth. Attic-substituted paths carry attic's signature into the
# mirror; locally built paths do not, so the mirror keeps a signing
# key of its own and require-sigs stays fully on. An absent or empty
# mirror (CI's pristine BUILD_CACHE_ID) degrades to attic-only
# behavior.
if [ -n "${NIX_MIRROR:-}" ] && [ -d "$NIX_MIRROR" ]; then
    # A bare directory is not yet a valid binary cache; seed the
    # nix-cache-info marker so nix accepts it as a substituter on the
    # very first run.
    if [ ! -f "$NIX_MIRROR/nix-cache-info" ]; then
        printf 'StoreDir: /nix/store\n' > "$NIX_MIRROR/nix-cache-info"
    fi
    MIRROR_KEY="$NIX_MIRROR/signing.sec"
    if [ ! -f "$MIRROR_KEY" ]; then
        log "Generating mirror signing key..."
        nix key generate-secret --key-name petros-mirror-1 \
            > "$MIRROR_KEY"
    fi
    MIRROR_PUB=$(nix key convert-secret-to-public < "$MIRROR_KEY")
    export NIX_CONFIG="extra-substituters = file://${NIX_MIRROR}?priority=10
extra-trusted-public-keys = ${MIRROR_PUB}"
    log "NAR mirror enabled: $NIX_MIRROR ($MIRROR_PUB)"
else
    NIX_MIRROR=""
    log "NAR mirror not mounted; substituting from attic only"
fi

# Check if we have write permission to the cache.
log "Checking write permissions for cache..."
HAS_WRITE_PERMISSION=false

# Build a minimal test derivation and try to push it.
# This is a reliable way to test write permissions.
TEST_PATH=$(nix build --no-link --print-out-paths --impure --expr \
    'derivation {
        name = "attic-write-test";
        system = builtins.currentSystem;
        builder = "/bin/sh";
        args = ["-c" "echo test > $out"];
    }')
if [ -n "$TEST_PATH" ] && \
    attic push "remote:${ATTIC_CACHE}" "$TEST_PATH" >/dev/null 2>&1; then
    HAS_WRITE_PERMISSION=true
    log "Write permission confirmed - will cache built derivations"
else
    log "No write permission (read-only token) - will build without" \
        "pushing"
fi

# Check if we have packages to build.
if [ $# -eq 0 ]; then
    echo "Usage: $0 <package-name> [package-name2 ...]"
    echo "Example: $0 bash coreutils gcc"
    exit 1
fi

# Process each package.
for PACKAGE in "$@"; do
    log "Processing package: $PACKAGE"

    # Get the derivation for this package.
    if [[ "$PACKAGE" == *.drv ]]; then
        # Direct derivation path provided.
        PACKAGE_DRV="$PACKAGE"
    elif [[ "$PACKAGE" == *#* ]]; then
        # Flake reference (e.g., .#bash, nixpkgs#hello).
        PACKAGE_DRV=$(nix eval --raw "$PACKAGE.drvPath")
    else
        # Assume nixpkgs attribute.
        PACKAGE_DRV=$(nix eval --raw "/nixpkgs#$PACKAGE.drvPath")
    fi

    # Check if the package itself is already available.
    log "Checking if $PACKAGE is already in attic..."

    # Use the package attribute directly, not the derivation.
    if [[ "$PACKAGE" == *#* ]]; then
        BUILD_TARGET="$PACKAGE"
    else
        BUILD_TARGET="/nixpkgs#$PACKAGE"
    fi

    DRY_RUN_OUTPUT=$(nix build --dry-run "$BUILD_TARGET" 2>&1 || true)

    # Check if anything will be built (meaning output not in cache).
    if echo "$DRY_RUN_OUTPUT" | grep -q "will be built"; then
        log "$PACKAGE needs to be built (not in cache)"
    elif echo "$DRY_RUN_OUTPUT" | grep -q "will be fetched"; then
        log "$PACKAGE is already substitutable, fetching..."
        PACKAGE_OUTPUT=$(nix build "$BUILD_TARGET" --no-link \
            --print-out-paths)
        log "$PACKAGE fetched from cache: $PACKAGE_OUTPUT"
        mirror_closure $PACKAGE_OUTPUT
        continue
    else
        log "$PACKAGE is already in local store"

        # Ensure package and its dependencies are in attic cache.
        PACKAGE_OUTPUT=$(nix build "$BUILD_TARGET" --no-link \
            --print-out-paths)
        log "Ensuring $PACKAGE and dependencies are in attic cache..."

        # Get the full runtime closure (built outputs).
        RUNTIME_PATHS=$(nix path-info --recursive $PACKAGE_OUTPUT)

        # Also get the derivation closure for complete coverage.
        DERIVATION_PATHS=$(nix path-info --derivation --recursive \
            $PACKAGE_OUTPUT)

        # Push both runtime outputs and derivations.
        if push_to_attic $RUNTIME_PATHS $DERIVATION_PATHS; then
            log "$PACKAGE closure pushed to attic cache"
        else
            log "WARNING: Failed to push $PACKAGE closure to attic"
        fi
        mirror_closure $PACKAGE_OUTPUT
        continue
    fi

    # If we get here, package needs to be built.
    log "$PACKAGE needs to be built, checking dependencies..."

    # Only check dependencies if the package itself needs building.
    log "Getting ALL $PACKAGE dependencies recursively..."
    ALL_DRVS=$(nix path-info --derivation --recursive "$PACKAGE_DRV" \
        | grep "\.drv$" || true)
    total=$(echo "$ALL_DRVS" | wc -l)

    log "Checking $total dependencies in attic (parallel)..."

    # Use temp files for parallel coordination.
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    count=0
    for drv in $ALL_DRVS; do
        count=$((count + 1))
        (
            # Check if outputs need to be built.
            DRY_RUN_OUTPUT=$(nix build --dry-run "$drv^*" 2>&1 || true)
            if echo "$DRY_RUN_OUTPUT" | grep -q "will be built"; then
                # Not available anywhere, needs building.
                echo "$drv" > "$TMPDIR/missing_$count"
            fi

            # "will be fetched" means available in substituter.
            # No output means already in local store.
            # Both cases mean we don't need to build it.
        ) &
    done
    wait

    # Collect missing derivations from temp files.
    MISSING_DRVS=""
    for f in "$TMPDIR"/missing_*; do
        if [ -f "$f" ]; then
            MISSING_DRVS="$MISSING_DRVS$(cat "$f") "
        fi
    done

    # Clean up temp files for this package.
    rm -rf "$TMPDIR"/missing_*

    # Build only missing dependencies sequentially.
    if [ -n "$MISSING_DRVS" ]; then
        missing_count=$(echo $MISSING_DRVS | wc -w)
        log "Found $missing_count dependencies to build for $PACKAGE"

        count=0
        for drv in $MISSING_DRVS; do
            count=$((count + 1))
            log "[$count/$missing_count] Building: $drv"

            if nix build "$drv^*" --print-out-paths --no-link \
                > "$TMPDIR/build_output_$count" 2>/dev/null; then
                OUTPUT=$(cat "$TMPDIR/build_output_$count")

                # Push the realized runtime closure, not just this
                # drv's outputs. Substitution can fail at realize time
                # after the check pass predicted a fetch; nix then
                # builds those deps implicitly inside this build, and
                # they appear only in this closure. Pushing only
                # $OUTPUT leaves them as permanent cache holes. Attic
                # uploads only what the cache is missing, so
                # re-offering present paths costs a presence check,
                # not a transfer.
                if [ "$HAS_WRITE_PERMISSION" = true ]; then
                    log "[$count/$missing_count] Success, pushing" \
                        "realized closure to attic: $OUTPUT"
                    CLOSURE=$(nix path-info --recursive $OUTPUT \
                        2>/dev/null || echo "$OUTPUT")
                    push_to_attic $CLOSURE $drv
                    log "[$count/$missing_count] Pushed to attic"
                else
                    log "[$count/$missing_count] Success: $OUTPUT"
                fi

                # Mirror per-drv, not only at the end, so a run that
                # dies partway keeps its completed work disk-warm.
                mirror_closure $OUTPUT
                rm -f "$TMPDIR/build_output_$count"
            else
                log "[$count/$missing_count] Failed: $drv"
            fi
        done
    else
        log "All dependencies for $PACKAGE already in attic!"
    fi

    # Finally, build the package itself.
    log "Building $PACKAGE..."
    if OUTPUT=$(nix build "$BUILD_TARGET" --print-out-paths --no-link \
        --max-jobs auto --cores 0); then
        log "Built $PACKAGE: $OUTPUT"

        # Push the final package's realized runtime closure and its
        # derivation; same hole-closing rationale as the per-drv loop.
        if [ "$HAS_WRITE_PERMISSION" = true ]; then
            CLOSURE=$(nix path-info --recursive $OUTPUT 2>/dev/null \
                || echo "$OUTPUT")
            if push_to_attic $CLOSURE $PACKAGE_DRV; then
                log "Successfully pushed $PACKAGE to attic"
            else
                log "WARNING: Failed to push $PACKAGE to attic"
            fi
        fi
        mirror_closure $OUTPUT
    else
        log "ERROR: $PACKAGE build failed!"
        exit 1
    fi

done

if [ "$HAS_WRITE_PERMISSION" = true ]; then
    log "Push summary: ${PUSH_OFFERED} paths offered," \
        "${PUSH_FAILED} failed"
    if [ "$PUSH_FAILED" -gt 0 ]; then
        log "WARNING: ${PUSH_FAILED} paths failed to push; they remain" \
            "cache holes until a future build re-offers them"
    fi
fi

log "All packages processed successfully"
