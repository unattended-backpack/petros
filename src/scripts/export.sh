#!/usr/bin/env sh
# export.sh - Export built Nix packages for the non-Nix final image as
# classed, deterministic chunk tarballs.
#
# Usage: export.sh <package> [package ...]
# Example: export.sh path:/build#petros
#
# The recursive closure of the given packages is partitioned into chunk
# classes, each packed as its own deterministic tarball under /export/.
# The runtime stage imports one chunk per docker layer, and BuildKit
# keys COPY --from layers on content digest, so a chunk whose bytes are
# unchanged is a cache hit even though this script reran after a builder
# invalidation, and only genuinely changed chunks are re-shipped and
# re-imported. Determinism: GNU tar (from the just-built env) with
# sorted member order and fixed ownership; store paths already carry
# epoch mtimes.
#
# Classes resolve the closure of the flake's chunk-* roots: tiny
# buildEnvs over derivations already inside the main env, intersected
# against the main closure. Every path goes to the first class that
# claims it; the remainder is the `base` chunk. A newly vendored large
# asset ships in `base` until it gets a class; the per-chunk size log
# below makes a bloating base visible.

set -euo pipefail

# Log messages with a consistent prefix.
log() {
    echo "[export] $*"
}

# Chunk classes in claim-priority order; class <name> is the closure of
# flake attr path:/build#chunk-<name>. Keep in sync with the runtime
# stage's COPY/RUN pairs in the Dockerfile (stability-ordered there).
CLASSES="cuda compilers zkvm"

# Ensure at least one package was specified.
if [ $# -eq 0 ]; then
    echo "Usage: $0 <package-name> [package-name2 ...]"
    echo "Example: $0 path:/build#petros"
    exit 1
fi

log "Exporting packages: $*"

# Create the export directory.
mkdir -p /export

# Get all package outputs (should already be built by build.sh).
ALL_PATHS=""
for pkg in "$@"; do
    log "Getting output path for $pkg..."

    # Use --offline to ensure we only use local store.
    if [[ "$pkg" == *#* ]]; then
        # Flake reference (e.g., path:/build#petros, nixpkgs#hello).
        out_path="$(nix build "$pkg" --no-link --print-out-paths \
            --offline)"
    else
        # Assume nixpkgs attribute.
        out_path="$(nix build /nixpkgs#$pkg --no-link \
            --print-out-paths --offline)"
    fi
    ALL_PATHS="$ALL_PATHS $out_path"
    log "  $pkg -> $out_path"
done

# Deterministic tars need GNU tar (busybox tar has no --sort); the env
# ships it (flake: gnutar in the petros paths).
FIRST_OUT=$(echo $ALL_PATHS | awk '{print $1}')
TAR="$FIRST_OUT/bin/tar"
if ! "$TAR" --version 2>/dev/null | grep -q "GNU tar"; then
    log "ERROR: $TAR is not GNU tar; chunk determinism requires it"
    exit 1
fi

# Get recursive closure of all packages.
log "Computing recursive closure..."
nix path-info --recursive $ALL_PATHS | sort > /tmp/closure.txt
closure_size=$(wc -l < /tmp/closure.txt)
log "Closure contains $closure_size store paths"

# Partition: the first class to claim a path wins; whatever no class
# claims becomes `base`. Chunk roots are subsets of the main env, so
# the intersection is belt-and-suspenders.
for class in $CLASSES; do
    root="path:/build#chunk-${class}"
    nix build "$root" --no-link --print-out-paths --offline > /dev/null
    nix path-info --recursive "$root" --offline | sort > /tmp/class.txt
    comm -12 /tmp/closure.txt /tmp/class.txt > "/tmp/chunk-${class}.txt"
    comm -23 /tmp/closure.txt /tmp/class.txt > /tmp/closure.rest
    mv /tmp/closure.rest /tmp/closure.txt
done
cp /tmp/closure.txt /tmp/chunk-base.txt

# Pack each chunk. Tar needs relative paths so strip the leading slash.
for class in $CLASSES base; do
    list="/tmp/chunk-${class}.txt"
    count=$(wc -l < "$list")
    sed 's|^/||' "$list" > "${list}.rel"
    "$TAR" -C / --sort=name --owner=0 --group=0 --numeric-owner \
        -cf "/export/${class}.tar" -T "${list}.rel"
    size=$(du -h "/export/${class}.tar" | cut -f1)
    log "Chunk ${class}: ${count} paths, ${size}"
done

# Save all output paths for reference (the runtime stage links /petros
# to the first).
echo "$ALL_PATHS" > /export/store.outpath

log "Export complete: /export/{ceremony,cuda,compilers,zkvm,base}.tar"
