#!/usr/bin/env sh
# vendor.sh - Download vendored dependencies for Petros
#
# This script downloads large binary dependencies that are too big for git.
# Checksums are verified to ensure integrity.

set -euo pipefail

# Log messages with a consistent prefix.
log() {
  echo "[vendor] $*"
}

# Base URL for vendored files.
VENDOR_BASE_URL="${VENDOR_BASE_URL}"
log "Downloading vendored dependencies..."
log "Using vendor URL: $VENDOR_BASE_URL"

# Function to download and verify a file
# Usage: download_and_verify <filename> <destination_directory>
download_and_verify() {
  local filename=$1
  local dest_dir=$2
  local file_path="${dest_dir}/${filename}"
  local checksum_file="${file_path}.sha256"
  local url="${VENDOR_BASE_URL}/${filename}"

  if [ -f "$file_path" ]; then
    log "File $file_path already exists, verifying checksum..."
    if (cd "$dest_dir" && sha256sum -c "${filename}.sha256" 2>/dev/null); then
      log "Checksum verified for $file_path"
      return 0
    else
      log "Checksum mismatch, re-downloading..."
      rm -f "$file_path"
    fi
  fi

  log "Downloading: $url"
  mkdir -p "$dest_dir"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$file_path" "$url"
  else
    log "ERROR: curl not found!"
    exit 1
  fi

  log "Verifying checksum for $file_path..."
  if (cd "$dest_dir" && sha256sum -c "${filename}.sha256"); then
    log "Downloaded and verified: $file_path"
  else
    log "ERROR: Checksum verification failed for $file_path"
    rm -f "$file_path"
    exit 1
  fi
}

# Download vendored files
download_and_verify "nix" "/tmp"
download_and_verify "attic-store.tar.gz" "/tmp"
download_and_verify "cargo_prove_v5.2.1_linux_amd64.tar.gz" "/tmp"
download_and_verify "rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" "/tmp"
log "All vendored dependencies downloaded and verified!"
