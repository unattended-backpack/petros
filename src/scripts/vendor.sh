#!/usr/bin/env sh
# vendor.sh - Download vendored dependencies for Petros
#
# This script downloads large binary dependencies that are too big for git.
# Checksums are verified to ensure integrity.
#
# Assets live at either a flat CDN path (legacy; tracked as follow-up) or
# under a namespaced + versioned path so that old petros commits remain
# reproducible after the maintainer bumps a toolchain.

set -euo pipefail

# Log messages with a consistent prefix.
log() {
  echo "[vendor] $*"
}

# Required build-time env vars.
VENDOR_BASE_URL="${VENDOR_BASE_URL}"
log "Downloading vendored dependencies..."
log "Using vendor URL: $VENDOR_BASE_URL"

# Download and verify a vendored file.
# Usage:
#   download_and_verify <filename> <local_dir> [<remote_prefix>]
#
# <remote_prefix> (optional) is appended to VENDOR_BASE_URL before <filename>,
# e.g. "sp1/v5.2.1/". When omitted the file is fetched flat from
# ${VENDOR_BASE_URL}/<filename>.
#
# <local_dir> is both the download target and where the committed
# <filename>.sha256 lives at build time; the Dockerfile is responsible for
# COPYing the relevant versioned src/ subdirectory into <local_dir>.
download_and_verify() {
  local filename=$1
  local dest_dir=$2
  local remote_prefix=${3:-}
  local file_path="${dest_dir}/${filename}"
  local url="${VENDOR_BASE_URL}/${remote_prefix}${filename}"

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

# --- Vendored assets ---------------------------------------------------------
# Each is namespaced by asset class and versioned so that any historical
# petros commit can be rebuilt byte-identically against what's on the CDN.
# The Dockerfile COPYs each src/<asset>/<version>/ subdirectory into a
# matching /tmp/<asset>/ before invoking us.

# Nix static binary — ${VENDOR_BASE_URL}/nix/${NIX_VERSION}/nix
if [ -z "${NIX_VERSION:-}" ]; then
  log "ERROR: NIX_VERSION is required for vendoring nix"
  exit 1
fi
download_and_verify "nix" "/tmp/nix" "nix/${NIX_VERSION}/"

# Attic-store closure — ${VENDOR_BASE_URL}/attic/${ATTIC_VERSION}/attic-store.tar.gz
if [ -z "${ATTIC_VERSION:-}" ]; then
  log "ERROR: ATTIC_VERSION is required for vendoring attic"
  exit 1
fi
download_and_verify "attic-store.tar.gz" "/tmp/attic" "attic/${ATTIC_VERSION}/"

# SP1 vendor assets — ${VENDOR_BASE_URL}/sp1/${SP1_VERSION}/...
if [ -z "${SP1_VERSION:-}" ]; then
  log "ERROR: SP1_VERSION is required for vendoring SP1 assets"
  exit 1
fi
download_and_verify "cargo_prove_${SP1_VERSION}_linux_amd64.tar.gz" \
  "/tmp/sp1" "sp1/${SP1_VERSION}/"
download_and_verify "rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" \
  "/tmp/sp1" "sp1/${SP1_VERSION}/"
# SP1 PLONK verification key (from the sp1-verifier crate); sha256(plonk_vk.bin)
# is the on-chain SP1VerifierPlonk VERIFIER_HASH the verification confirms.
download_and_verify "plonk_vk.bin" "/tmp/sp1" "sp1/${SP1_VERSION}/"

# RISC Zero vendor assets — ${VENDOR_BASE_URL}/risc0/${RISC0_TOOLCHAIN_VERSION}/...
if [ -z "${RISC0_TOOLCHAIN_VERSION:-}" ]; then
  log "ERROR: RISC0_TOOLCHAIN_VERSION is required for vendoring RISC Zero assets"
  exit 1
fi
download_and_verify "rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" \
  "/tmp/risc0" "risc0/${RISC0_TOOLCHAIN_VERSION}/"

# RISC Zero CPP cross-toolchain — ${VENDOR_BASE_URL}/risc0/cpp/${RISC0_CPP_TOOLCHAIN_VERSION}/...
# riscv32im-unknown-elf gcc/g++ for cross-compiling the risc0-zkvm guest
# crate's C/C++ syscall-stub layer.
if [ -z "${RISC0_CPP_TOOLCHAIN_VERSION:-}" ]; then
  log "ERROR: RISC0_CPP_TOOLCHAIN_VERSION is required for vendoring RISC Zero CPP toolchain"
  exit 1
fi
download_and_verify "riscv32im-linux-x86_64.tar.xz" \
  "/tmp/risc0-cpp" "risc0/cpp/${RISC0_CPP_TOOLCHAIN_VERSION}/"

# snarkjs node_modules — ${VENDOR_BASE_URL}/snarkjs/${SNARKJS_VERSION}/...
if [ -z "${SNARKJS_VERSION:-}" ]; then
  log "ERROR: SNARKJS_VERSION is required for vendoring snarkjs"
  exit 1
fi
download_and_verify "snarkjs-node-modules.tar.gz" \
  "/tmp/snarkjs" "snarkjs/${SNARKJS_VERSION}/"

# RISC Zero Groth16 ceremony artifacts —
# ${VENDOR_BASE_URL}/risc0/groth16/${R0_GROTH16_VERSION}/...
# The verification reproduces the r1cs from the circom sources, then
# snarkjs-verifies the 238-contribution chain against the ptau + zkey, and
# greps control_id.rs for the official control root.
if [ -z "${R0_GROTH16_VERSION:-}" ]; then
  log "ERROR: R0_GROTH16_VERSION is required for vendoring RISC Zero Groth16 artifacts"
  exit 1
fi
for f in powersOfTau28_hez_final_23.ptau stark_verify_final.zkey \
         stark_verify.circom risc0.circom control_id.rs; do
  download_and_verify "$f" "/tmp/risc0-groth16" "risc0/groth16/${R0_GROTH16_VERSION}/"
done

# circom binary — ${VENDOR_BASE_URL}/circom/${CIRCOM_VERSION}/circom
if [ -z "${CIRCOM_VERSION:-}" ]; then
  log "ERROR: CIRCOM_VERSION is required for vendoring circom"
  exit 1
fi
download_and_verify "circom" "/tmp/circom" "circom/${CIRCOM_VERSION}/"

# SP1 Aztec Ignition consumed-points bundle —
# ${VENDOR_BASE_URL}/sp1/ignition/ignition-points.bin
download_and_verify "ignition-points.bin" "/tmp/ignition" "sp1/ignition/"

log "All vendored dependencies downloaded and verified!"
