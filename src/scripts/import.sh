#!/usr/bin/env sh
# import.sh - Import exported Nix packages into a non-Nix system.
# Usage: import.sh <store.tar> <store.outpath>
# This script extracts the tarball and creates symlinks for binaries.

set -euo pipefail

# Validate arguments.
if [ $# -ne 2 ]; then
    echo "Usage: $0 <store.tar> <store.outpath>"
    exit 1
fi

STORE_TAR="$1"
STORE_OUTPATH="$2"

# Extract the Nix store tarball.
echo "[import] Extracting Nix store from $STORE_TAR..."
tar -C / -xf "$STORE_TAR"
rm -f "$STORE_TAR"

# Create /petros symlink to the buildEnv output.
echo "[import] Creating /petros symlink..."
out_path=$(cat "$STORE_OUTPATH" | tr -d ' ')
ln -sf "$out_path" /petros
echo "[import]   /petros -> $out_path"

echo "[import] Import complete"
