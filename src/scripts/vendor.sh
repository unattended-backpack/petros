#!/usr/bin/env sh
# vendor.sh - Download vendored dependencies for Petros
#
# This script downloads large binary dependencies that are too big for git.
# Checksums are verified to ensure integrity.
#
# Usage: vendor.sh [<asset-class>...]
#   With arguments, only the named asset classes are vendored (the
#   Dockerfile invokes one class per cached layer, so a bumped or newly
#   added asset never re-fetches the others). With no arguments, every
#   class is vendored.
#
# When VENDOR_CACHE_DIR is set (a BuildKit cache mount in the Dockerfile),
# downloads are served from and mirrored into it. Cache hits are verified
# against the committed sha256 pins exactly like fresh downloads, so a
# stale or polluted cache can fail loudly but never inject bytes; CI
# disables the warm cache entirely via DOCKER_BUILD_CACHE=0.
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

# Asset-class filter (see header). `want <class>` is true when the class
# was requested or when no filter was given.
ASSETS="$*"
want() {
  [ -z "$ASSETS" ] && return 0
  case " $ASSETS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

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

  # Optional persistent download cache: serve a hit only if it passes the
  # committed pin, and discard it loudly otherwise.
  local cache_path=""
  if [ -n "${VENDOR_CACHE_DIR:-}" ]; then
    cache_path="${VENDOR_CACHE_DIR}/${remote_prefix}${filename}"
    if [ -f "$cache_path" ]; then
      mkdir -p "$dest_dir"
      cp "$cache_path" "$file_path"
      if (cd "$dest_dir" && sha256sum -c "${filename}.sha256" >/dev/null 2>&1); then
        log "Cache hit (pin-verified): $cache_path"
        return 0
      fi
      log "Cached copy failed its pin, discarding: $cache_path"
      rm -f "$file_path" "$cache_path"
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

  # Mirror the verified bytes into the cache for the next build.
  if [ -n "$cache_path" ]; then
    mkdir -p "$(dirname "$cache_path")"
    cp "$file_path" "$cache_path"
  fi
}

# --- Vendored assets ---------------------------------------------------------
# Each is namespaced by asset class and versioned so that any historical
# petros commit can be rebuilt byte-identically against what's on the CDN.
# The Dockerfile COPYs each src/<asset>/<version>/ subdirectory into a
# matching /tmp/<asset>/ before invoking us.

if want nix; then
  # Nix static binary: ${VENDOR_BASE_URL}/nix/${NIX_VERSION}/nix
  if [ -z "${NIX_VERSION:-}" ]; then
    log "ERROR: NIX_VERSION is required for vendoring nix"
    exit 1
  fi
  download_and_verify "nix" "/tmp/nix" "nix/${NIX_VERSION}/"
fi

if want attic; then
  # Attic-store closure: ${VENDOR_BASE_URL}/attic/${ATTIC_VERSION}/attic-store.tar.gz
  if [ -z "${ATTIC_VERSION:-}" ]; then
    log "ERROR: ATTIC_VERSION is required for vendoring attic"
    exit 1
  fi
  download_and_verify "attic-store.tar.gz" "/tmp/attic" "attic/${ATTIC_VERSION}/"
fi

if want sp1; then
  # SP1 vendor assets: ${VENDOR_BASE_URL}/sp1/${SP1_VERSION}/...
  if [ -z "${SP1_VERSION:-}" ]; then
    log "ERROR: SP1_VERSION is required for vendoring SP1 assets"
    exit 1
  fi
  download_and_verify "cargo_prove_${SP1_VERSION}_linux_amd64.tar.gz" \
    "/tmp/sp1" "sp1/${SP1_VERSION}/"
  if [ -z "${SP1_RUST_TOOLCHAIN:-}" ]; then
    log "ERROR: SP1_RUST_TOOLCHAIN is required for vendoring the SP1 toolchain"
    exit 1
  fi
  download_and_verify "rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" \
    "/tmp/sp1" "sp1/toolchain/${SP1_RUST_TOOLCHAIN}/"
  # SP1 PLONK verification key (from the sp1-verifier crate); sha256(plonk_vk.bin)
  # is the on-chain SP1VerifierPlonk VERIFIER_HASH the verification confirms.
  if [ -z "${SP1_CIRCUIT_VERSION:-}" ]; then
    log "ERROR: SP1_CIRCUIT_VERSION is required for vendoring the SP1 PLONK vk"
    exit 1
  fi
  download_and_verify "plonk_vk.bin" "/tmp/sp1" "sp1/${SP1_CIRCUIT_VERSION}/"
fi

if want risc0; then
  # RISC Zero vendor assets: ${VENDOR_BASE_URL}/risc0/${RISC0_TOOLCHAIN_VERSION}/...
  if [ -z "${RISC0_TOOLCHAIN_VERSION:-}" ]; then
    log "ERROR: RISC0_TOOLCHAIN_VERSION is required for vendoring RISC Zero assets"
    exit 1
  fi
  download_and_verify "rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" \
    "/tmp/risc0" "risc0/${RISC0_TOOLCHAIN_VERSION}/"
fi

if want risc0-cpp; then
  # RISC Zero CPP cross-toolchain: ${VENDOR_BASE_URL}/risc0/cpp/${RISC0_CPP_TOOLCHAIN_VERSION}/...
  # riscv32im-unknown-elf gcc/g++ for cross-compiling the risc0-zkvm guest
  # crate's C/C++ syscall-stub layer.
  if [ -z "${RISC0_CPP_TOOLCHAIN_VERSION:-}" ]; then
    log "ERROR: RISC0_CPP_TOOLCHAIN_VERSION is required for vendoring RISC Zero CPP toolchain"
    exit 1
  fi
  download_and_verify "riscv32im-linux-x86_64.tar.xz" \
    "/tmp/risc0-cpp" "risc0/cpp/${RISC0_CPP_TOOLCHAIN_VERSION}/"
fi

if want snarkjs; then
  # snarkjs node_modules: ${VENDOR_BASE_URL}/snarkjs/${SNARKJS_VERSION}/...
  if [ -z "${SNARKJS_VERSION:-}" ]; then
    log "ERROR: SNARKJS_VERSION is required for vendoring snarkjs"
    exit 1
  fi
  download_and_verify "snarkjs-node-modules.tar.gz" \
    "/tmp/snarkjs" "snarkjs/${SNARKJS_VERSION}/"
fi

if want risc0-groth16; then
  # RISC Zero Groth16 ceremony artifacts:
  # ${VENDOR_BASE_URL}/risc0/groth16/${R0_GROTH16_VERSION}/...
  # The verification reproduces the r1cs from the circom sources, then
  # snarkjs-verifies the 238-contribution chain against the ptau + zkey, and
  # greps control_id.rs for the official control root.
  if [ -z "${R0_GROTH16_VERSION:-}" ]; then
    log "ERROR: R0_GROTH16_VERSION is required for vendoring RISC Zero Groth16 artifacts"
    exit 1
  fi
  # attestation-gists.tar.gz + the upstream verification doc snapshot are
  # the ceremony's identity-anchoring layer: the 198 contributor
  # attestation gists (archived 2026-08-18; gists are user-deletable, so
  # this is preservation of decaying evidence) that the verification
  # cross-checks against contribution hashes recomputed from the zkey.
  for f in powersOfTau28_hez_final_23.ptau stark_verify_final.zkey \
           stark_verify.circom risc0.circom control_id.rs \
           attestation-gists.tar.gz risc0-trusted-setup-ceremony.md; do
    download_and_verify "$f" "/tmp/risc0-groth16" "risc0/groth16/${R0_GROTH16_VERSION}/"
  done
fi

if want openvm; then
  # OpenVM vendor assets: ${VENDOR_BASE_URL}/openvm/${OPENVM_VERSION}/...
  # The guest toolchain is a stock upstream nightly captured from a real
  # `rustup toolchain install` (manifests included; see flake.nix's openvm_tc
  # note), and cargo-openvm is built once from the pinned tag (no upstream
  # prebuilt exists).
  if [ -z "${OPENVM_VERSION:-}" ]; then
    log "ERROR: OPENVM_VERSION is required for vendoring OpenVM assets"
    exit 1
  fi
  if [ -z "${OPENVM_RUST_TOOLCHAIN:-}" ]; then
    log "ERROR: OPENVM_RUST_TOOLCHAIN is required for vendoring the OpenVM toolchain"
    exit 1
  fi
  download_and_verify "rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" \
    "/tmp/openvm" "openvm/toolchain/${OPENVM_RUST_TOOLCHAIN}/"
  download_and_verify "cargo-openvm_${OPENVM_VERSION}_linux_amd64.tar.gz" \
    "/tmp/openvm" "openvm/${OPENVM_VERSION}/"
fi

if want openvm-kzg; then
  # OpenVM KZG params: ${VENDOR_BASE_URL}/openvm/kzg/${OPENVM_KZG_VERSION}/...
  # The PSE-halo2-format SRS files openvm's EVM prover consumes, converted
  # upstream from Perpetual Powers of Tau challenge_0085. Every file is
  # hash-pinned individually so a single srs can be re-verified in isolation.
  if [ -z "${OPENVM_KZG_VERSION:-}" ]; then
    log "ERROR: OPENVM_KZG_VERSION is required for vendoring OpenVM KZG params"
    exit 1
  fi
  for k in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
    download_and_verify "kzg_bn254_${k}.srs" \
      "/tmp/openvm-kzg" "openvm/kzg/${OPENVM_KZG_VERSION}/"
  done
fi

if want solidity; then
  # solc static binary: ${VENDOR_BASE_URL}/solidity/${SOLC_VERSION}/...
  # The exact compiler openvm-sdk shells out to when emitting the EVM
  # verifier bytecode during `cargo openvm setup --evm` (the generated
  # contracts pin `pragma solidity 0.8.19` exactly, so the nixpkgs solc
  # cannot substitute). Mirror of the official static build published at
  # binaries.soliditylang.org/linux-amd64 (hash matches upstream list.json).
  if [ -z "${SOLC_VERSION:-}" ]; then
    log "ERROR: SOLC_VERSION is required for vendoring solc"
    exit 1
  fi
  download_and_verify "solc-static-linux" \
    "/tmp/solidity" "solidity/${SOLC_VERSION}/"
fi

if want circom; then
  # circom binary: ${VENDOR_BASE_URL}/circom/${CIRCOM_VERSION}/circom
  if [ -z "${CIRCOM_VERSION:-}" ]; then
    log "ERROR: CIRCOM_VERSION is required for vendoring circom"
    exit 1
  fi
  download_and_verify "circom" "/tmp/circom" "circom/${CIRCOM_VERSION}/"
fi

if want ignition; then
  # SP1 Aztec Ignition consumed-points bundle plus identity anchors:
  # ${VENDOR_BASE_URL}/sp1/ignition/... The manifest names the 181
  # participants (address-keyed folders) and signatures.tar.gz holds all
  # 3520 per-transcript ECDSA signatures scraped from the live
  # aztec-ignition bucket 2026-08-18; together they tie the pinned
  # points bundle's contribution chain to public Ethereum identities.
  for f in ignition-points.bin manifest.json participants.txt \
           signatures.tar.gz; do
    download_and_verify "$f" "/tmp/ignition" "sp1/ignition/"
  done
fi

if want ppot; then
  # Perpetual Powers of Tau chain evidence (phase 1 for BOTH the RISC
  # Zero Hermez ptau, contributions 1..54 + beacon, and the OpenVM SRS,
  # state after contribution 84): ${VENDOR_BASE_URL}/ppot/${PPOT_VERSION}/...
  # pot28_0086_nopoints.ptau carries the full 67-record contribution
  # chain (snarkjs format, powers stripped; sourced from the ceremony
  # repo's 0086_nebra_response/ dir); ppot_0080_contributions.bin is an
  # independent extraction of records 1..61 from PSE's prepared file;
  # the response_0084/challenge_0085 slices are raw-mirror cross-binds
  # (Axiom's bucket); the repo bundle is the attestation/identity layer;
  # archive-metadata.tar.gz preserves torrents, infohashes, and
  # availability inventories. See docs/CEREMONY_ANCHORS.md.
  if [ -z "${PPOT_VERSION:-}" ]; then
    log "ERROR: PPOT_VERSION is required for vendoring PPoT chain evidence"
    exit 1
  fi
  for f in pot28_0086_nopoints.ptau ppot_0080_contributions.bin \
           response_0084_pubkey.bin response_0084_prev_challenge_hash.bin \
           challenge_0085_head.bin perpetualpowersoftau-repo.bundle \
           archive-metadata.tar.gz; do
    download_and_verify "$f" "/tmp/ppot" "ppot/${PPOT_VERSION}/"
  done
fi

if want ethereum-kzg; then
  # Ethereum KZG Summoning Ceremony (BLS12-381; the [tau]_2 embedded in
  # Sigil's L2 point-evaluation precompile and the L1 blob-binding
  # path): ${VENDOR_BASE_URL}/ethereum-kzg/${ETH_KZG_VERSION}/...
  # transcript.json is the full 141,417-contribution sequencer
  # transcript (the EF sequencer no longer resolves; fetched from the
  # ethereum/kzg-ceremony git-LFS archive); trusted_setup_4096.json is
  # the derived setup whose g2_monomial[1] the consensus constant must
  # equal.
  if [ -z "${ETH_KZG_VERSION:-}" ]; then
    log "ERROR: ETH_KZG_VERSION is required for vendoring Ethereum KZG artifacts"
    exit 1
  fi
  download_and_verify "transcript.json" \
    "/tmp/ethereum-kzg" "ethereum-kzg/${ETH_KZG_VERSION}/"
  download_and_verify "trusted_setup_4096.json" \
    "/tmp/ethereum-kzg" "ethereum-kzg/${ETH_KZG_VERSION}/"
fi

log "All vendored dependencies downloaded and verified!"
