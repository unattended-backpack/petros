#!/usr/bin/env sh
# generate-openvm-verifier-pin.sh - Emit the OpenVM EVM verifier contracts
# from the pinned production halo2.pk and print/write the content pin that
# populates src/openvm/halo2/<OPENVM_HALO2_VERSION>/verifier.expected-hashes.
#
# What this produces (in the output dir)
#   verifier.expected-hashes        sha256 lines over the four artifacts in
#                                   sacristy's vendored layout:
#                                     OpenVmHalo2Verifier.bin
#                                     Halo2Verifier.sol
#                                     OpenVmHalo2Verifier.sol
#                                     interfaces/IOpenVmHalo2Verifier.sol
#   verifier/                       the artifacts themselves, for manual
#                                   comparison against sacristy's
#                                   contracts/src/l2/verifier/vendor/openvm/
#
# Trust story: the emitted contracts derive from the CDN-pinned halo2.pk,
# i.e. the exact proving key hierophant proves with, so the pin binds the
# deployed contracts to production proving. Whether that key itself is
# honest is the trusted-setup verification's job (regenerate the key from
# code + params and compare; see docs/OPENVM_TRUSTED_SETUP.md).
#
# Fast by construction: the verifier-pin-tool loads the seeded key and
# injects it into the SDK, skipping the ~70-GB-RAM halo2 keygen that
# `cargo openvm setup --evm` would run (the SDK derives the verifier from
# its in-memory key; a seeded key file alone does not prevent keygen).
#
# How to run
#   `make openvm-verifier-pin` from the petros checkout, or by hand inside
#   a petros container with this script, the tool source, and an output
#   dir mounted; see the Makefile goal.

set -eu

OUT_DIR="${1:-$PWD}"
TOOL_DIR="${2:-/tool}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found; run inside a petros container" >&2
  exit 1
fi
# Execute rather than `command -v`: a staged-but-unrunnable binary (e.g.
# missing ELF interpreter) must fail here, not hours into codegen.
if ! solc --version >/dev/null 2>&1; then
  echo "ERROR: solc not found or not executable; rebuild petros with the solidity vendor" >&2
  exit 1
fi
: "${VENDOR_BASE_URL:?must be set (halo2.pk seed source)}"
: "${OPENVM_VERSION:?must be set (SDK base dir path component)}"
: "${OPENVM_HALO2_VERSION:?must be set (halo2.pk seed path component)}"

OPENVM_MM=$(echo "${OPENVM_VERSION#v}" | cut -d. -f1-2)
VERSION_DIR="v${OPENVM_MM}-base"

# Seed the KZG params from the copies petros bakes, and halo2.pk from the
# vendor CDN, exactly as generate-openvm-agg-keys.sh does.
echo "[verifier-pin] Seeding KZG params (checksum-gated fetch into the cache) ..."
: "${OPENVM_KZG_VERSION:?must be set (SRS path component)}"
mkdir -p "$HOME/.openvm/params" /ceremony-cache/openvm-kzg
for k in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
  f="kzg_bn254_${k}.srs"
  if ! (cd /ceremony-cache/openvm-kzg \
      && sha256sum -c "/pins-kzg/${f}.sha256" >/dev/null 2>&1); then
    curl -fsSL "${VENDOR_BASE_URL}/openvm/kzg/${OPENVM_KZG_VERSION}/${f}" \
      -o "/ceremony-cache/openvm-kzg/${f}"
    (cd /ceremony-cache/openvm-kzg && sha256sum -c "/pins-kzg/${f}.sha256")
  fi
  cp "/ceremony-cache/openvm-kzg/${f}" "$HOME/.openvm/params/"
done
echo "[verifier-pin] Seeding halo2.pk from the vendor CDN ..."
curl -fsSL "${VENDOR_BASE_URL}/openvm/halo2/${OPENVM_HALO2_VERSION}/openvm-halo2-pk.tar.gz" \
  | tar -xzf - -C "$HOME/.openvm"

# The seeded key must match the committed content pin before anything is
# derived from it.
echo "[verifier-pin] Verifying seeded halo2.pk against the committed pin ..."
PIN_FILE="/petros/share/openvm/halo2.pk.sha256"
if [ ! -f "$PIN_FILE" ]; then
  # Fall back to a mounted checkout copy for pre-rebuild runs.
  PIN_FILE="${HALO2_PK_SHA256:?halo2.pk.sha256 not staged and HALO2_PK_SHA256 unset}"
fi
PIN_HASH=$(awk '{print $1}' "$PIN_FILE")
GOT_HASH=$(sha256sum "$HOME/.openvm/halo2.pk" | awk '{print $1}')
if [ "$GOT_HASH" != "$PIN_HASH" ]; then
  echo "ERROR: seeded halo2.pk hash $GOT_HASH != pinned $PIN_HASH" >&2
  exit 1
fi
echo "[verifier-pin] halo2.pk matches pin ($PIN_HASH)"

# Build the tool with the vendored petros toolchain, pinned by its
# committed Cargo.lock.
echo "[verifier-pin] Building verifier-pin-tool (network: crates.io) ..."
TOOL_TARGET="$HOME/verifier-pin-target"
(cd "$TOOL_DIR" && CARGO_TARGET_DIR="$TOOL_TARGET" cargo build --release --locked)

echo "[verifier-pin] Emitting verifier (codegen + solc; minutes) ..."
EMIT_DIR="$HOME/verifier-emit"
"$TOOL_TARGET/release/verifier-pin-tool" \
  "$HOME/.openvm/halo2.pk" "$EMIT_DIR" "$VERSION_DIR"

# Normalize into sacristy's vendored layout: the three sources verbatim
# plus the creation bytecode as bare hex (no 0x, no trailing newline).
SRC_DIR="$EMIT_DIR/src/$VERSION_DIR"
if [ ! -f "$SRC_DIR/OpenVmHalo2Verifier.sol" ]; then
  echo "ERROR: expected emitted sources under $SRC_DIR; found:" >&2
  find "$EMIT_DIR" -type f >&2
  exit 1
fi
OUT_V="$OUT_DIR/verifier"
mkdir -p "$OUT_V/interfaces"
cp "$SRC_DIR/Halo2Verifier.sol" "$OUT_V/"
cp "$SRC_DIR/OpenVmHalo2Verifier.sol" "$OUT_V/"
cp "$SRC_DIR/interfaces/IOpenVmHalo2Verifier.sol" "$OUT_V/interfaces/"
jq -r .bytecode "$SRC_DIR/verifier.bytecode.json" \
  | tr -d '\n' > "$OUT_V/OpenVmHalo2Verifier.bin"

echo "[verifier-pin] Writing pin ..."
(cd "$OUT_V" && sha256sum \
  OpenVmHalo2Verifier.bin \
  Halo2Verifier.sol \
  OpenVmHalo2Verifier.sol \
  interfaces/IOpenVmHalo2Verifier.sol) > "$OUT_DIR/verifier.expected-hashes"

echo "[verifier-pin] Done. Pin contents:"
cat "$OUT_DIR/verifier.expected-hashes"
echo "[verifier-pin] Commit these lines to src/openvm/${OPENVM_VERSION}/verifier.expected-hashes,"
echo "[verifier-pin] rebuild petros, then run sacristy's 'make verify-bindings'. If the"
echo "[verifier-pin] bindings check reports a mismatch against sacristy's vendored files,"
echo "[verifier-pin] diff them against $OUT_DIR/verifier/ before changing anything."
