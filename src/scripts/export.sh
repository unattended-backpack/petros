#!/usr/bin/env sh
# export.sh - Export built Nix packages for non-Nix final image.
# Usage: export.sh <package> [package ...]
# Example: export.sh bash coreutils gcc

set -euo pipefail

# Log messages with a consistent prefix.
log() {
    echo "[export] $*"
}

# Ensure at least one package was specified.
if [ $# -eq 0 ]; then
    echo "Usage: $0 <package-name> [package-name2 ...]"
    echo "Example: $0 bash coreutils gcc"
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
        # Flake reference (e.g., path:/build#ci, nixpkgs#hello).
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

# Get recursive closure of all packages.
log "Computing recursive closure..."
nix path-info --recursive $ALL_PATHS > /tmp/closure.txt
closure_size=$(wc -l < /tmp/closure.txt)
log "Closure contains $closure_size store paths"

# Pack the exact store paths as a tar (for "no Nix" final).
# Tar needs relative paths so strip the leading slash.
log "Creating tarball..."
sed 's|^/||' /tmp/closure.txt > /tmp/closure.rel.txt
tar -C / -cf /export/store.tar -T /tmp/closure.rel.txt

# Save all output paths for reference.
echo "$ALL_PATHS" > /export/store.outpath

tar_size=$(du -h /export/store.tar | cut -f1)
log "Export complete: /export/store.tar ($tar_size)"
