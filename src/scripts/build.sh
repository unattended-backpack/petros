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
# Falls back to individual pushes if batch push fails.
# Args: $@ - store paths to push
push_to_attic() {
    if [ "$HAS_WRITE_PERMISSION" != true ]; then
        return 0
    fi

    if attic push "remote:${ATTIC_CACHE}" "$@" 2>&1; then
        return 0
    fi

    # Batch push failed, try individually.
    log "WARNING: Batch push failed, retrying individually..."
    for path in "$@"; do
        attic push "remote:${ATTIC_CACHE}" "$path" 2>&1 || \
            log "Failed to push: $path"
    done
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
        log "$PACKAGE is already in attic, fetching..."
        PACKAGE_OUTPUT=$(nix build "$BUILD_TARGET" --no-link \
            --print-out-paths)
        log "$PACKAGE fetched from cache: $PACKAGE_OUTPUT"
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

                # Push outputs and derivation to attic.
                if [ "$HAS_WRITE_PERMISSION" = true ]; then
                    log "[$count/$missing_count] Success, pushing to" \
                        "attic: $OUTPUT"
                    push_to_attic $OUTPUT $drv
                    log "[$count/$missing_count] Pushed to attic"
                else
                    log "[$count/$missing_count] Success: $OUTPUT"
                fi
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

        # Push the final package outputs and derivation to attic.
        if [ "$HAS_WRITE_PERMISSION" = true ]; then
            if push_to_attic $OUTPUT $PACKAGE_DRV; then
                log "Successfully pushed $PACKAGE to attic"
            else
                log "WARNING: Failed to push $PACKAGE to attic"
            fi
        fi
    else
        log "ERROR: $PACKAGE build failed!"
        exit 1
    fi

done

log "All packages processed successfully"
