#!/usr/bin/env sh
# verify-openvm-kzg.sh - Offline structural verification of the vendored
# OpenVM KZG params (kzg_bn254_{10..24}.srs).
#
# What this proves
#   1. Every file matches its committed sha256 pin.
#   2. Every file has exactly the size the PSE-halo2 ParamsKZG serialization
#      implies for its k: 4 (LE u32 k) + 2^k * 64 (monomial G1, uncompressed)
#      + 2^k * 64 (Lagrange G1) + 128 (g2) + 128 (s_g2).
#   3. Every file's 4-byte header equals its k.
#   4. The monomial G1 section of every k < 24 file is a byte-exact prefix of
#      the k=24 file's monomial section, and the 256-byte [g2, s_g2] tail is
#      identical across all fifteen files. Together these prove the fifteen
#      files are consistent slices of ONE underlying SRS - no file can carry
#      a different tau.
#
# What this does NOT prove
#   That the one underlying SRS actually derives from Perpetual Powers of Tau
#   challenge_0085. That is the ceremony re-derivation documented in
#   docs/OPENVM_TRUSTED_SETUP.md: convert the ceremony transcript with the
#   pinned converter and byte-compare against these files. Run that once per
#   OPENVM_KZG_VERSION bump on a machine with the disk for the ~97 GB
#   transcript; run THIS script anywhere, offline, in seconds per gigabyte.
#
# Usage
#   sh verify-openvm-kzg.sh <dir>
#     <dir> contains kzg_bn254_{10..24}.srs and their .sha256 sidecars
#     (a checkout's src/openvm/kzg/challenge_0085/, or /petros/share/openvm-kzg
#     plus the sidecars from the checkout).

set -eu

DIR="${1:?usage: verify-openvm-kzg.sh <dir with kzg_bn254_K.srs + .sha256>}"
cd "$DIR"

K_MIN=10
K_MAX=24
REF="kzg_bn254_${K_MAX}.srs"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Hash pins.
for k in $(seq $K_MIN $K_MAX); do
  f="kzg_bn254_${k}.srs"
  [ -f "$f" ] || fail "$f missing"
  [ -f "$f.sha256" ] || fail "$f.sha256 missing"
  sha256sum -c "$f.sha256" >/dev/null || fail "$f sha256 mismatch"
done
echo "OK: all 15 files match their committed sha256 pins"

# 2 + 3. Sizes and headers. Sizes are 4 + 2^(k+1)*64 + 256; headers are the
# LE u32 k. od is POSIX; -A n suppresses offsets, -t u4 prints the LE u32.
for k in $(seq $K_MIN $K_MAX); do
  f="kzg_bn254_${k}.srs"
  expect_size=$((4 + (1 << (k + 1)) * 64 + 256))
  actual_size=$(wc -c < "$f")
  [ "$actual_size" -eq "$expect_size" ] || \
    fail "$f size $actual_size != expected $expect_size"
  header=$(od -A n -t u4 -N 4 "$f" | tr -d ' ')
  [ "$header" = "$k" ] || fail "$f header k=$header != $k"
done
echo "OK: all sizes and k headers match the ParamsKZG layout"

# 4a. Monomial-prefix consistency against the k=24 reference. The monomial
# G1 section spans bytes [4, 4 + 2^k*64) in each file. Stage the reference
# slice in a temp file and cmp the candidate's slice against it via stdin;
# plain dd/head/cmp so the check runs under strict POSIX sh. The largest
# slice (k=23, 512 MiB) is staged once and shrinking slices reuse nothing,
# so worst-case temp usage is one 512 MiB file at a time.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for k in $(seq $K_MIN $((K_MAX - 1))); do
  f="kzg_bn254_${k}.srs"
  mono_bytes=$(((1 << k) * 64))
  dd if="$REF" bs=4 skip=1 2>/dev/null | head -c "$mono_bytes" > "$tmp"
  dd if="$f" bs=4 skip=1 2>/dev/null | head -c "$mono_bytes" | \
    cmp -s - "$tmp" || fail "$f monomial section is not a prefix of $REF"
done
rm -f "$tmp"
echo "OK: every monomial G1 section is a byte-exact prefix of $REF"

# 4b. Identical [g2, s_g2] tails (last 256 bytes) across all files.
ref_tail=$(tail -c 256 "$REF" | od -A n -t x1 | tr -d ' \n')
for k in $(seq $K_MIN $((K_MAX - 1))); do
  f="kzg_bn254_${k}.srs"
  tail_hex=$(tail -c 256 "$f" | od -A n -t x1 | tr -d ' \n')
  [ "$tail_hex" = "$ref_tail" ] || fail "$f [g2, s_g2] tail differs from $REF"
done
echo "OK: [g2, s_g2] tails identical across all 15 files"

echo "PASS: vendored OpenVM KZG params are internally consistent slices of one SRS"
echo "NOTE: ceremony provenance (PPoT challenge_0085) is established separately;"
echo "      see docs/OPENVM_TRUSTED_SETUP.md."
