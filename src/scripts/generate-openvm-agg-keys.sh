#!/usr/bin/env sh
# generate-openvm-agg-keys.sh - Generate and package the OpenVM aggregation
# proving keys that downstream Hierophant images stage into ~/.openvm/.
#
# What this produces
#   openvm-agg-keys.tar.gz          containing:
#     internal_recursive.pk         the universal internal-recursive proving
#                                   key (program- and app-config-independent)
#     internal_recursive.vk         its verifying key
#     root.pk                       the root aggregation proving key; the SDK
#                                   requires it whenever halo2.pk is seeded
#                                   (EVM-mode workers), and it is equally
#                                   universal
#   openvm-agg-keys.tar.gz.sha256   committed downstream; the tarball itself
#                                   is uploaded to the CDN at
#                                   ${VENDOR_BASE_URL}/openvm/halo2/<OPENVM_HALO2_VERSION>/
#
# These are outputs of `cargo openvm setup --evm`: deterministic keygen, no
# trusted-setup ceremony involved. The --evm pass would normally also
# download params and generate the ~70-GB-RAM halo2 key, so this script
# SEEDS both first - the KZG params from the copies petros bakes at
# /petros/share/openvm-kzg and halo2.pk from the vendor CDN - which reduces
# the run to the aggregation keygens themselves (minutes of CPU, tens of GB
# of RAM at peak). Generated once here and vendored instead of regenerated
# in-process by every worker and hierophant.
#
# How to run
#   `make openvm-agg-keys` from the petros checkout (wraps the docker run on
#   a large-memory machine; 64 GB+ recommended), or by hand inside a petros
#   container with this script and an output dir mounted:
#     docker run --rm -v "$PWD/src/scripts":/provision:ro -v "$PWD/out":/out \
#       petros:latest sh /provision/generate-openvm-agg-keys.sh /out
#
# Reproducibility
#   The keygen is deterministic: re-running this script on independent
#   hardware must produce a byte-identical tarball payload. Verify a vendored
#   artifact by regenerating on a second machine and comparing the sha256 of
#   the *contained files* (tar metadata such as mtimes can differ; compare
#   `sha256sum internal_recursive.pk internal_recursive.vk` from both runs).
#   A mismatch means toolchain or upstream-source drift and must be
#   investigated before the artifact is trusted.

set -eu

OUT_DIR="${1:-$PWD}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found; run inside a petros container" >&2
  exit 1
fi
: "${VENDOR_BASE_URL:?must be set (halo2.pk seed source)}"
: "${OPENVM_VERSION:?must be set (SDK base dir path component)}"
: "${OPENVM_HALO2_VERSION:?must be set (halo2.pk seed path component)}"

# Seed the KZG params from the copies petros bakes, and halo2.pk from the
# vendor CDN, so `setup --evm` skips both the params download and the
# ~70-GB-RAM halo2 keygen and only runs the aggregation keygens.
echo "[agg-keys] Seeding KZG params (checksum-gated fetch into the cache) ..."
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
echo "[agg-keys] Seeding halo2.pk from the vendor CDN ..."
curl -fsSL "${VENDOR_BASE_URL}/openvm/halo2/${OPENVM_HALO2_VERSION}/openvm-halo2-pk.tar.gz" \
  | tar -xzf - -C "$HOME/.openvm"

# Seed placeholder verifier artifacts so setup SKIPS its final
# verifier-generation step. Petros now vendors solc, so that step no
# longer fails fast; left to run, it would trigger the full in-memory
# halo2 keygen this script seeds halo2.pk precisely to avoid (the SDK
# derives the verifier from its in-memory key, not the seeded file).
# The real verifier emission is generate-openvm-verifier-pin.sh, which
# loads the seeded key. Placeholders die with the container; the
# packaged bundle below never includes them.
OPENVM_MM=$(echo "${OPENVM_VERSION#v}" | cut -d. -f1-2)
VDIR="$HOME/.openvm/halo2/src/v${OPENVM_MM}-base"
mkdir -p "$VDIR/interfaces"
touch "$VDIR/Halo2Verifier.sol" "$VDIR/OpenVmHalo2Verifier.sol" \
  "$VDIR/verifier.bytecode.json" "$VDIR/interfaces/IOpenVmHalo2Verifier.sol"

echo "[agg-keys] Running cargo openvm setup --evm (agg + root keygen; slow, RAM-heavy) ..."
# All three keys are written before the (skipped) verifier step, so the
# per-file checks below remain the real gate: they hard-fail if setup
# died before producing any key.
cargo openvm setup --evm || \
  echo "[agg-keys] setup exited nonzero; continuing to key checks"

for f in internal_recursive.pk internal_recursive.vk root.pk; do
  if [ ! -f "$HOME/.openvm/$f" ]; then
    echo "ERROR: expected $HOME/.openvm/$f after setup; not found" >&2
    exit 1
  fi
done

echo "[agg-keys] Key hashes (compare these across independent runs):"
(cd "$HOME/.openvm" && sha256sum internal_recursive.pk internal_recursive.vk root.pk)

echo "[agg-keys] Packaging ..."
mkdir -p "$OUT_DIR"
tar -C "$HOME/.openvm" -czf "$OUT_DIR/openvm-agg-keys.tar.gz" \
  internal_recursive.pk internal_recursive.vk root.pk
(cd "$OUT_DIR" && sha256sum openvm-agg-keys.tar.gz > openvm-agg-keys.tar.gz.sha256)

echo "[agg-keys] Done:"
ls -la "$OUT_DIR/openvm-agg-keys.tar.gz" "$OUT_DIR/openvm-agg-keys.tar.gz.sha256"
echo "[agg-keys] Upload the tarball to \${VENDOR_BASE_URL}/openvm/halo2/<OPENVM_HALO2_VERSION>/"
echo "[agg-keys] and commit the .sha256 under hierophant's provers/openvm/<OPENVM_VERSION>/."
