#!/usr/bin/env sh
# bootstrap-attic.sh - Create vendored attic tarball for bootstrapping
# Run this script with your cache temporarily public to vendor attic binaries.
# Usage: ./src/scripts/bootstrap-attic.sh

set -euo pipefail

log() {
    echo "[bootstrap_attic] $*"
}

log "Building attic-client and attic-server..."

# Build attic-client and attic-server
ATTIC_CLIENT=$(nix build nixpkgs#attic-client --print-out-paths --no-link)
ATTIC_SERVER=$(nix build nixpkgs#attic-server --print-out-paths --no-link)

log "Attic client: $ATTIC_CLIENT"
log "Attic server: $ATTIC_SERVER"

# Get the full closure (all dependencies)
log "Computing closure..."
nix path-info --recursive $ATTIC_CLIENT $ATTIC_SERVER > /tmp/attic-closure.txt

closure_size=$(wc -l < /tmp/attic-closure.txt)
log "Closure contains $closure_size store paths"

# Create tarball (strip leading slash for tar)
log "Creating tarball..."
sed 's|^/||' /tmp/attic-closure.txt > /tmp/attic-closure.rel.txt
tar -C / -czf src/attic/attic-store.tar.gz -T /tmp/attic-closure.rel.txt

# Save the output paths
echo "$ATTIC_CLIENT" > src/attic/attic-client.outpath
echo "$ATTIC_SERVER" > src/attic/attic-server.outpath

# Create checksum (use just the filename, not the full path)
cd src/attic && sha256sum attic-store.tar.gz > attic-store.tar.gz.sha256 && cd ../..

tar_size=$(du -h src/attic/attic-store.tar.gz | cut -f1)
log "Created src/attic/attic-store.tar.gz ($tar_size)"
log "Created src/attic/attic-client.outpath"
log "Created src/attic/attic-server.outpath"
log "Created src/attic/attic-store.tar.gz.sha256"
log ""
log "Bootstrap complete! You can now make your cache private again."
log "The vendored attic will be used during Docker builds."

# Clean up
rm /tmp/attic-closure.txt /tmp/attic-closure.rel.txt
