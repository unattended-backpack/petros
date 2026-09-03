FROM alpine:3.20@sha256:765942a4039992336de8dd5db680586e1a206607dd06170ff0a37267a9e01958 AS builder

# Prepare environment variables from required arguments.
# Validate that the `ATTIC_SERVER_URL` is specified.
# Build arguments are declared bare (no guard RUN, no ENV mirror): a bare
# ARG creates no cache-relevant layer, so changing one value invalidates
# only the layers that actually consume it instead of everything below
# this line. Non-empty enforcement lives in the Makefile (fail-fast at
# invocation) and in vendor.sh (per asset class); RUN steps read the
# stage-local ARG values from their environment directly.
ARG ATTIC_SERVER_URL

# The `ATTIC_CACHE` must specify an available cache on the attic server.
ARG ATTIC_CACHE

# The `ATTIC_PUBLIC_KEY` must specify the public key of the attic server.
ARG ATTIC_PUBLIC_KEY

# The `VENDOR_BASE_URL` specifies where to download vendored dependencies.
ARG VENDOR_BASE_URL

# SP1 release that drives the path for both vendored SP1 assets (cargo-prove
# CLI + succinct rust toolchain). Tarballs live at
# ${VENDOR_BASE_URL}/sp1/${SP1_VERSION}/... with their sha256s committed at
# src/sp1/${SP1_VERSION}/.
ARG SP1_VERSION

# RISC Zero rust toolchain version: matches the directory name rzup uses
# under ~/.risc0/toolchains/v<VER>-rust-<target>/, and the path component on
# the vendor CDN under ${VENDOR_BASE_URL}/risc0/${RISC0_TOOLCHAIN_VERSION}/.
ARG RISC0_TOOLCHAIN_VERSION

# RISC Zero CPP cross-toolchain version: matches the directory name rzup
# uses under ~/.risc0/toolchains/v<VER>-cpp-<target>/, and the path on the
# vendor CDN under ${VENDOR_BASE_URL}/risc0/cpp/${RISC0_CPP_TOOLCHAIN_VERSION}/.
# Provides the riscv32im-unknown-elf gcc/g++ cross-toolchain that the
# risc0-zkvm guest crate's build.rs uses to compile its C/C++ syscall-stub
# layer into the guest ELF.
ARG RISC0_CPP_TOOLCHAIN_VERSION

# OpenVM release that drives the path for both vendored OpenVM assets
# (guest rust toolchain + cargo-openvm CLI). Tarballs live at
# ${VENDOR_BASE_URL}/openvm/${OPENVM_VERSION}/... with their sha256s
# committed at src/openvm/${OPENVM_VERSION}/.
ARG OPENVM_VERSION
# Derived-artifact axes: the halo2 keys track the OpenVM minor line;
# the toolchains and the SP1 circuit artifacts track their own upstream
# versions. See docs/VENDORING.md.
ARG OPENVM_HALO2_VERSION
ARG SP1_RUST_TOOLCHAIN
ARG SP1_CIRCUIT_VERSION

# The rustup channel name of the stock nightly OpenVM pins for guest builds
# (openvm-build's DEFAULT_RUSTUP_TOOLCHAIN_NAME). Names the toolchain
# directory materialized under $RUSTUP_HOME in the runtime stage; bump in
# lockstep with OPENVM_VERSION when upstream re-pins.
ARG OPENVM_RUST_TOOLCHAIN

# OpenVM KZG params set: the Perpetual Powers of Tau contribution the vendored
# kzg_bn254_{10..24}.srs files were converted from, at
# ${VENDOR_BASE_URL}/openvm/kzg/${OPENVM_KZG_VERSION}/...
ARG OPENVM_KZG_VERSION

# solc static-binary release, vendored for openvm-sdk's EVM verifier
# bytecode emission (`cargo openvm setup --evm` shells out to `solc`;
# the generated contracts pin solidity 0.8.19 exactly). Assets at
# ${VENDOR_BASE_URL}/solidity/${SOLC_VERSION}/ with the sha256 committed
# at src/solidity/${SOLC_VERSION}/.
ARG SOLC_VERSION

# Upstream attic snapshot tag (from the `attic-*.outpath` nix store path
# suffix). Pins the attic-store closure + its two .outpath files.
ARG ATTIC_VERSION

# Upstream nix release whose static binary is vendored here.
ARG NIX_VERSION

# circom version: binary at ${VENDOR_BASE_URL}/circom/${CIRCOM_VERSION}/circom.
ARG CIRCOM_VERSION

# snarkjs version: node_modules tarball at
# ${VENDOR_BASE_URL}/snarkjs/${SNARKJS_VERSION}/snarkjs-node-modules.tar.gz.
ARG SNARKJS_VERSION

# RISC Zero Groth16 ceremony artifacts: ptau, zkey, circom sources,
# control_id.rs, and the contributor attestation-gist archive at
# ${VENDOR_BASE_URL}/risc0/groth16/${R0_GROTH16_VERSION}/...
ARG R0_GROTH16_VERSION

# Perpetual Powers of Tau chain evidence (contribution records, raw-mirror
# cross-bind slices, ceremony-repo bundle) at
# ${VENDOR_BASE_URL}/ppot/${PPOT_VERSION}/... Named by the latest ceremony
# contribution the record chain covers.
ARG PPOT_VERSION

# Ethereum KZG Summoning Ceremony transcript + derived trusted setup at
# ${VENDOR_BASE_URL}/ethereum-kzg/${ETH_KZG_VERSION}/... Named by the
# ceremony's end date.
ARG ETH_KZG_VERSION

# Validate that our `attic_token` secret is mounted.
RUN --mount=type=secret,id=attic_token \
  test -f /run/secrets/attic_token || ( \
    echo "ERROR: attic_token secret is required!" >&2 \
    && exit 1)

# Prepare the build image with vendored packages.
WORKDIR /build
COPY flake.nix flake.nix
COPY src/nixpkgs/ /nixpkgs/
COPY src/scripts/build.sh /build/src/scripts/build.sh
COPY src/scripts/export.sh /build/src/scripts/export.sh
COPY src/scripts/vendor.sh /build/src/scripts/vendor.sh
ENV PATH="/usr/local/bin:/root/.nix-profile/bin:${PATH}"

# Dynamically prepare `nix.conf` from build arguments.
COPY nix.conf /etc/nix/nix.conf
RUN cat >> /etc/nix/nix.conf <<EOF
substituters = ${ATTIC_SERVER_URL}/${ATTIC_CACHE}
trusted-public-keys = ${ATTIC_CACHE}:${ATTIC_PUBLIC_KEY}
EOF

# Copy and verify vendored CA certificates for SSL verification.
COPY src/certs/cacert.pem.sha256 /tmp/cacert.pem.sha256
COPY src/certs/cacert.pem /tmp/cacert.pem
RUN cd /tmp && sha256sum -c cacert.pem.sha256 || ( \
    echo "ERROR: CA certificate bundle checksum mismatch!" >&2 \
    && exit 1) \
  && mkdir -p /etc/ssl/certs /nix/var/nix/ssl \
  && cp /tmp/cacert.pem /etc/ssl/certs/ca-bundle.crt \
  && cp /tmp/cacert.pem /nix/var/nix/ssl/ca-bundle.crt \
  && rm /tmp/cacert.pem.sha256 /tmp/cacert.pem

# Configure Nix and curl to use vendored CA certificates.
ENV NIX_SSL_CERT_FILE=/nix/var/nix/ssl/ca-bundle.crt
ENV SSL_CERT_FILE=/nix/var/nix/ssl/ca-bundle.crt
ENV CURL_CA_BUNDLE=/nix/var/nix/ssl/ca-bundle.crt

# Verify our included static curl.
COPY src/curl/curl.sha256 /tmp/curl.sha256
COPY src/curl/curl /tmp/curl
RUN cd /tmp && sha256sum -c curl.sha256 || ( \
    echo "ERROR: curl binary checksum mismatch!" >&2 \
    && exit 1) \
  && mv /tmp/curl /usr/local/bin/curl \
  && rm /tmp/curl.sha256

# Download vendored dependencies from self-hosted source, one asset class
# per (COPY + RUN) layer pair so a version bump or a newly vendored asset
# only re-fetches from its own layer down; append new assets at the END
# of this chain. Docker layer caching is prefix-based, so the pairs are
# ordered stability-first (infra and ceremony artifacts that rarely bump,
# then the zkVM toolchains). Each RUN mounts a persistent BuildKit
# download cache: re-fetches after an invalidation refill from local disk
# and every hit is still verified against the committed sha256 pin, so a
# stale cache can fail loudly but never inject bytes. The cache namespace
# follows hierophant's DOCKER_BUILD_CACHE convention; CI passes a unique
# BUILD_CACHE_ID (pristine-<epoch>) so full release builds start from an
# empty mount.
ARG BUILD_CACHE_ID=shared
COPY src/nix/${NIX_VERSION}/ /tmp/nix/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh nix
COPY src/attic/${ATTIC_VERSION}/ /tmp/attic/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh attic
COPY src/circom/${CIRCOM_VERSION}/ /tmp/circom/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh circom
COPY src/snarkjs/${SNARKJS_VERSION}/ /tmp/snarkjs/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh snarkjs
COPY src/risc0/groth16/${R0_GROTH16_VERSION}/ /tmp/risc0-groth16/
COPY src/sp1/ignition/ /tmp/ignition/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh ignition
COPY src/sp1/${SP1_VERSION}/ /tmp/sp1/
COPY src/sp1/toolchain/${SP1_RUST_TOOLCHAIN}/ /tmp/sp1/
COPY src/sp1/${SP1_CIRCUIT_VERSION}/plonk_vk.bin.sha256 /tmp/sp1/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh sp1
COPY src/risc0/${RISC0_TOOLCHAIN_VERSION}/ /tmp/risc0/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh risc0
COPY src/risc0/cpp/${RISC0_CPP_TOOLCHAIN_VERSION}/ /tmp/risc0-cpp/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh risc0-cpp
COPY src/openvm/${OPENVM_VERSION}/ /tmp/openvm/
COPY src/openvm/toolchain/${OPENVM_RUST_TOOLCHAIN}/ /tmp/openvm/
COPY src/openvm/halo2/${OPENVM_HALO2_VERSION}/ /tmp/openvm-halo2/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh openvm
COPY src/openvm/kzg/${OPENVM_KZG_VERSION}/ /tmp/openvm-kzg/
COPY src/solidity/${SOLC_VERSION}/ /tmp/solidity/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh solidity
COPY src/ppot/${PPOT_VERSION}/ /tmp/ppot/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh ppot
COPY src/ethereum-kzg/${ETH_KZG_VERSION}/ /tmp/ethereum-kzg/
RUN --mount=type=cache,id=petros-vendor-${BUILD_CACHE_ID},target=/vendor-cache \
  VENDOR_CACHE_DIR=/vendor-cache /build/src/scripts/vendor.sh ethereum-kzg

# Install static Nix.
RUN mv /tmp/nix/nix /usr/local/bin/nix \
  && chmod +x /usr/local/bin/nix \
  && rm -rf /tmp/nix

# Prepare the statically-vendored Nix with store and build users.
RUN mkdir -p /nix/store /nix/var/nix/profiles/per-user/root; \
 addgroup -S nixbld; \
 for i in $(seq 0 31); do adduser -S -D -H -G nixbld nixbld$i; done

# Extract vendored attic binaries before using private substituters.
# This solves the chicken-and-egg problem of needing attic to authenticate
# against the private cache, but needing the cache to get attic. The attic
# tarball + its two outpath files arrived via COPY src/attic/${ATTIC_VERSION}/
# → /tmp/attic/ above; vendor.sh downloaded attic-store.tar.gz alongside.
RUN tar -C / -xzf /tmp/attic/attic-store.tar.gz \
  && ATTIC_CLIENT=$(cat /tmp/attic/attic-client.outpath) \
  && ATTIC_SERVER=$(cat /tmp/attic/attic-server.outpath) \
  && ln -s $ATTIC_CLIENT/bin/attic /usr/local/bin/attic \
  && ln -s $ATTIC_SERVER/bin/atticadm /usr/local/bin/atticadm \
  && rm -rf /tmp/attic

# Validate that the `ATTIC_SERVER_URL` is accessible.
RUN curl --fail --silent --show-error \
  --max-time 10 --retry 0 "${ATTIC_SERVER_URL}" > /dev/null || ( \
    echo "ERROR: ATTIC_SERVER_URL '${ATTIC_SERVER_URL}' is unreachable!" >&2 \
    && exit 1)

# Extract vendored SP1 tarballs to directories for `flake.nix` PATH URLs.
# flake input paths (/build/src/sp1/sp1-cli, /build/src/sp1/sp1-tc) stay
# version-stable; versioning lives in the vendor paths (/tmp/sp1/…) and the
# SP1_VERSION env var.
RUN mkdir -p /build/src/sp1/sp1-cli && \
  tar -xzf /tmp/sp1/cargo_prove_${SP1_VERSION}_linux_amd64.tar.gz \
    -C /build/src/sp1/sp1-cli/ && \
  rm -rf /tmp/sp1/cargo_prove_${SP1_VERSION}_linux_amd64.tar.gz \
         /tmp/sp1/cargo_prove_${SP1_VERSION}_linux_amd64.tar.gz.sha256
RUN mkdir -p /build/src/sp1/sp1-tc && \
  tar -xzf /tmp/sp1/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
    -C /build/src/sp1/sp1-tc/ && \
  rm -rf /tmp/sp1/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
         /tmp/sp1/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz.sha256

# Place the SP1 PLONK VK (no extraction) at its flake input path, then drop the
# rest of /tmp/sp1 (the leftover .sha256).
RUN mkdir -p /build/src/sp1/plonk-vk && \
  mv /tmp/sp1/plonk_vk.bin /build/src/sp1/plonk-vk/plonk_vk.bin && \
  rm -rf /tmp/sp1

# Extract vendored RISC Zero toolchain to the path flake.nix points at.
RUN mkdir -p /build/src/risc0/risc0-tc && \
  tar -xzf /tmp/risc0/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
    -C /build/src/risc0/risc0-tc/ && \
  rm -rf /tmp/risc0/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
         /tmp/risc0/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz.sha256

# Extract vendored RISC Zero CPP cross-toolchain to the path flake.nix points
# at. The xz-compressed tarball expands to a top-level `riscv32im-linux-x86_64/`
# directory that rzup itself preserves (paths.rs notes "C++ archive has a
# child directory we want to ignore"; we keep it for parity with rzup).
RUN mkdir -p /build/src/risc0/risc0-cpp-tc && \
  tar -xJf /tmp/risc0-cpp/riscv32im-linux-x86_64.tar.xz \
    -C /build/src/risc0/risc0-cpp-tc/ && \
  rm -rf /tmp/risc0-cpp/riscv32im-linux-x86_64.tar.xz \
         /tmp/risc0-cpp/riscv32im-linux-x86_64.tar.xz.sha256

# Extract the vendored OpenVM guest toolchain to the path flake.nix points
# at. The tarball root is the *contents* of a rustup-installed
# `<channel>-x86_64-unknown-linux-gnu/` toolchain directory, including the
# lib/rustlib/ install manifests the runtime stage's rustup component
# preflight depends on (see flake.nix's openvm_tc note).
RUN mkdir -p /build/src/openvm/openvm-tc && \
  tar -xzf /tmp/openvm/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
    -C /build/src/openvm/openvm-tc/ && \
  rm -rf /tmp/openvm/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
         /tmp/openvm/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz.sha256

# Place the committed OpenVM content pins at the flake input path: the
# verifier pin (comment-only until `make openvm-verifier-pin` populates
# it; downstream checks fail closed) and the halo2.pk content pin the
# trusted-setup reproduction compares its freshly generated key against.
RUN mkdir -p /build/src/openvm/verifier-pin && \
  cp /tmp/openvm-halo2/verifier.expected-hashes /build/src/openvm/verifier-pin/ && \
  cp /tmp/openvm-halo2/halo2.pk.sha256 /build/src/openvm/verifier-pin/

# Extract the vendored cargo-openvm CLI to the path flake.nix points at.
RUN mkdir -p /build/src/openvm/openvm-cli && \
  tar -xzf /tmp/openvm/cargo-openvm_${OPENVM_VERSION}_linux_amd64.tar.gz \
    -C /build/src/openvm/openvm-cli/ && \
  rm -rf /tmp/openvm

# Stage the ceremony checksum pins at the ceremony-pins flake input
# path. The large artifacts themselves are not baked; downstream
# verification and the openvm keygen goals fetch them from the vendor
# CDN at use time, gated on these pins.
RUN mkdir -p /build/src/ceremony-pins/risc0-groth16 \
             /build/src/ceremony-pins/openvm-kzg && \
  cp /tmp/risc0-groth16/*.sha256 /build/src/ceremony-pins/risc0-groth16/ && \
  cp /tmp/openvm-kzg/*.sha256 /build/src/ceremony-pins/openvm-kzg/ && \
  rm -rf /tmp/openvm-kzg

# Place the verified solc static binary at the solc flake input path.
RUN mkdir -p /build/src/solidity/solc && \
  install -m755 /tmp/solidity/solc-static-linux /build/src/solidity/solc/solc && \
  rm -rf /tmp/solidity

# Stage the vendored-version strings the flake derivations read
# (flake.nix readVersion), so derivation names always track
# .env.maintainer instead of hardcoded strings.
RUN mkdir -p /build/src/versions && \
  printf '%s' "${SP1_VERSION#v}" > /build/src/versions/sp1-cli && \
  printf '%s' "${SP1_RUST_TOOLCHAIN}" > /build/src/versions/sp1-tc && \
  printf 'r0-%s' "${RISC0_TOOLCHAIN_VERSION}" > /build/src/versions/risc0-tc && \
  printf 'r0-cpp-%s' "${RISC0_CPP_TOOLCHAIN_VERSION}" > /build/src/versions/risc0-cpp-tc && \
  printf '%s' "${OPENVM_RUST_TOOLCHAIN}" > /build/src/versions/openvm-tc && \
  printf '%s' "${OPENVM_VERSION#v}" > /build/src/versions/openvm-cli && \
  printf '%s' "${CIRCOM_VERSION#v}" > /build/src/versions/circom && \
  printf '%s' "${SOLC_VERSION#v}" > /build/src/versions/solc

# Extract the vendored snarkjs node_modules to the snarkjs flake input path.
RUN mkdir -p /build/src/snarkjs && \
  tar -xzf /tmp/snarkjs/snarkjs-node-modules.tar.gz \
    -C /build/src/snarkjs/ && \
  rm -rf /tmp/snarkjs

RUN rm -rf /tmp/risc0-groth16

# Place the verified circom binary (autopatchelf'd by the flake) and the SP1
# Ignition bundle + identity anchors at their flake input paths; the
# per-transcript signature archive extracts to a browsable sigs/ tree.
RUN mkdir -p /build/src/circom && \
  mv /tmp/circom/circom /build/src/circom/circom && \
  rm -rf /tmp/circom
RUN mkdir -p /build/src/ignition && \
  mv /tmp/ignition/ignition-points.bin /tmp/ignition/manifest.json \
     /tmp/ignition/participants.txt /build/src/ignition/ && \
  tar -xzf /tmp/ignition/signatures.tar.gz -C /build/src/ignition/ && \
  rm -rf /tmp/ignition

# Place the verified PPoT chain evidence and Ethereum KZG ceremony
# artifacts at their flake input paths, dropping the .sha256 sidecars.
# The repo bundle and archive-metadata tarball stay packed; they are
# archival provenance, not verification-leg inputs.
RUN mkdir -p /build/src/ppot && \
  cp /tmp/ppot/* /build/src/ppot/ && \
  rm -f /build/src/ppot/*.sha256 && \
  rm -rf /tmp/ppot
RUN mkdir -p /build/src/ethereum-kzg && \
  cp /tmp/ethereum-kzg/* /build/src/ethereum-kzg/ && \
  rm -f /build/src/ethereum-kzg/*.sha256 && \
  rm -rf /tmp/ethereum-kzg

# Register our vendored nixpkgs as the default
RUN nix registry add nixpkgs path:/nixpkgs
RUN nix flake metadata .

# Accept token hash to bust cache when token changes (without exposing secret).
ARG ATTIC_CACHE_BUST
RUN echo "Cache bust: ${ATTIC_CACHE_BUST}"

# Build and cache the complete Petros environment. The initial build may
# take a very long time depending on what is cached in attic. The NAR
# mirror cache mount keeps re-runs disk-warm: build.sh substitutes from
# it ahead of attic and copies realized closures back in after builds;
# an empty or absent mirror (CI's pristine BUILD_CACHE_ID) degrades to
# attic-only behavior. NIX_MIRROR is passed inline rather than baked
# into nix.conf so the vendor layer chain above stays untouched.
RUN --mount=type=secret,id=attic_token \
  --mount=type=cache,id=petros-nix-mirror-${BUILD_CACHE_ID},target=/nix-mirror \
  NIX_MIRROR=/nix-mirror \
  /build/src/scripts/build.sh path:/build#petros

# Prepare an export of packages for the final image.
# Export the entire Petros environment which includes all tools
RUN /build/src/scripts/export.sh path:/build#petros

# Petros is a final, minimal build image containing only our exported packages
# with Nix removed.
FROM alpine:3.20@sha256:765942a4039992336de8dd5db680586e1a206607dd06170ff0a37267a9e01958 AS petros

# Re-declare build-args we need in the runtime stage; ARGs don't carry across
# stages. The rzup layout setup below interpolates these into the toolchain
# directory names rzup expects, and the rustup layout setup interpolates the
# OpenVM channel name.
ARG OPENVM_RUST_TOOLCHAIN
ENV OPENVM_RUST_TOOLCHAIN=${OPENVM_RUST_TOOLCHAIN}

ARG RISC0_TOOLCHAIN_VERSION
ENV RISC0_TOOLCHAIN_VERSION=${RISC0_TOOLCHAIN_VERSION}

ARG RISC0_CPP_TOOLCHAIN_VERSION
ENV RISC0_CPP_TOOLCHAIN_VERSION=${RISC0_CPP_TOOLCHAIN_VERSION}

# OCI image labels for metadata and documentation.
LABEL org.opencontainers.image.title="Petros"
LABEL org.opencontainers.image.source=https://github.com/unattended-backpack/petros
LABEL org.opencontainers.image.description=\
"Upon this rock, I will build my church. Petros is a supply-chain-hardened build image for Sigil."
LABEL org.opencontainers.image.vendor="Unattended Backpack, Inc."
LABEL org.opencontainers.image.licenses="LicenseRef-VPL WITH AGPL-3.0-only"
LABEL org.opencontainers.image.base.name="docker.io/library/alpine:3.20"
LABEL org.opencontainers.image.base.digest=\
"sha256:765942a4039992336de8dd5db680586e1a206607dd06170ff0a37267a9e01958"

# Import the exported store, one classed chunk per bind-mounted RUN
# layer. The tarballs are never COPY'd into the image (a COPY layer
# would permanently double each chunk's size); BuildKit keys the RUN on
# the mounted tar's content digest, and export.sh writes deterministic
# tars, so a chunk whose bytes are unchanged is a cache hit even when
# the builder stage reran, and only genuinely changed chunks re-import.
# Stability order: the ceremony artifacts (~17 GB) and CUDA redists
# almost never change; the zkVM toolchains bump most often; `base`
# holds everything unclaimed (including any newly vendored asset until
# export.sh gives it a class). Keep the pair list in sync with
# export.sh's CLASSES.
RUN --mount=type=bind,from=builder,source=/export/cuda.tar,target=/tmp/chunk.tar \
  tar -C / -xf /tmp/chunk.tar
RUN --mount=type=bind,from=builder,source=/export/compilers.tar,target=/tmp/chunk.tar \
  tar -C / -xf /tmp/chunk.tar
RUN --mount=type=bind,from=builder,source=/export/zkvm.tar,target=/tmp/chunk.tar \
  tar -C / -xf /tmp/chunk.tar
RUN --mount=type=bind,from=builder,source=/export/base.tar,target=/tmp/chunk.tar \
  --mount=type=bind,from=builder,source=/export/store.outpath,target=/tmp/store.outpath \
  tar -C / -xf /tmp/chunk.tar \
  && ln -sf "$(tr -d ' ' < /tmp/store.outpath)" /petros

# Link binaries into the Succinct toolchain.
RUN set -eux; \
  ln -sf /petros/bin/cargo /petros/opt/succinct/bin/cargo; \
  ln -sf /petros/bin/rustfmt /petros/opt/succinct/bin/rustfmt \
    || true; \
  ln -sf /petros/bin/rustdoc /petros/opt/succinct/bin/rustdoc \
    || true

# Link binaries into the RISC Zero toolchain. The vendored risc0 tarball
# ships its own cargo/rustc/rustfmt/rustdoc; we overlay the petros-provided
# cargo so nested `cargo` invocations (e.g. build.rs spawning cargo to
# compile the guest crate) resolve consistently; rustfmt/rustdoc are opt-in:
# the toolchain tarball may or may not include them, so tolerate absence.
RUN set -eux; \
  ln -sf /petros/bin/cargo /petros/opt/risc0/bin/cargo; \
  ln -sf /petros/bin/rustfmt /petros/opt/risc0/bin/rustfmt \
    || true; \
  ln -sf /petros/bin/rustdoc /petros/opt/risc0/bin/rustdoc \
    || true

# Create an unprivileged user named `petros`.
RUN set -eux; \
  uid=10001; gid=10001; user=petros; home=/home/${user}; \
  echo "${user}:x:${uid}:${gid}:${user}:${home}:/bin/sh" \
    >> /etc/passwd; \
  echo "${user}:x:${gid}:" >> /etc/group; \
  mkdir -p "${home}"; \
  chown -R ${uid}:${gid} "${home}"
ENV HOME=/home/petros
ENV RUSTUP_HOME=/home/petros/.rustup
ENV CARGO_HOME=/home/petros/.cargo
ENV PATH=/home/petros/.sp1-shims/bin:/home/petros/.cargo/bin:\
/petros/bin:$PATH
ENV PKG_CONFIG_PATH=/petros/lib/pkgconfig
ENV CC=clang
ENV LIBCLANG_PATH=/petros/lib
USER 10001:10001

# Test that all expected binaries are working.
COPY src/scripts/test.sh /home/petros/test.sh
RUN sh /home/petros/test.sh bash ls cat echo openssl curl jq gpg \
  pkg-config rustc cargo node docker doctl cosign crane make file protoc go clang perl \
  circom snarkjs solc && \
  rm /home/petros/test.sh
RUN which cargo-prove
RUN cargo prove --version
RUN attic --version
RUN atticadm --version
RUN cosign version

# Link the Succinct toolchain into `rustup` so `cargo +succinct ...` works.
# We don't also link the RISC Zero toolchain here: risc0-build bypasses rustup
# entirely and uses the `rzup` library for toolchain discovery (see below).
RUN mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
  rustup toolchain link succinct /petros/opt/succinct; \
  rustup toolchain list

# Materialize the OpenVM guest toolchain under $RUSTUP_HOME as an
# *official-channel* install, NOT a `rustup toolchain link` like succinct
# above. openvm-build's preflight (`ensure_toolchain_installed`) runs
# `rustup component list --toolchain <tc>` and requires `rust-src
# (installed)`; linked custom toolchains don't support component operations,
# so the link route fails that check. A real directory named with the full
# channel triple, containing the lib/rustlib/ install manifests the vendored
# tarball preserves, answers both `rustup toolchain list` and the component
# query offline.
#
# The top-level directory is a real mkdir (rustup discovers toolchains by
# readdir) populated with symlinks into /petros/opt/openvm/, so the ~800 MB
# toolchain stays in /nix/store via buildEnv's existing symlinks.
#
# Deliberately NOT overlaying /petros/bin/cargo into this toolchain (unlike
# the succinct/risc0 blocks above): guest builds run `-Z build-std`, which
# requires the nightly's own cargo. `rustup run <tc> cargo` (via the
# wrapped_cargo +toolchain path) prepends the toolchain's bin/ to PATH, so
# nested cargo/rustc invocations stay inside the nightly.
RUN set -eux; \
  TC_DIR="$RUSTUP_HOME/toolchains/${OPENVM_RUST_TOOLCHAIN}-x86_64-unknown-linux-gnu"; \
  mkdir -p "$TC_DIR"; \
  for entry in /petros/opt/openvm/*; do \
    ln -s "$entry" "$TC_DIR/$(basename "$entry")"; \
  done; \
  rustup toolchain list

# Verify the offline arrangement at image-build time: the component
# preflight openvm-build performs must see rust-src installed, and rustup
# must resolve the toolchain's own cargo. Failing here is far cheaper than
# failing at first guest build downstream. (The `cargo +<tc>` and
# `cargo openvm` spellings both route through the wrapped_cargo script,
# which is COPY'd at the end of this file; their checks live there.)
RUN rustup component list --toolchain "${OPENVM_RUST_TOOLCHAIN}" \
  | grep 'rust-src (installed)'
RUN rustup run "${OPENVM_RUST_TOOLCHAIN}" cargo --version

# Expose the RISC Zero toolchain in the rzup-compatible layout that risc0-build
# (via the rzup crate) expects when resolving the rustc path. See
# risc0-build's `rust_toolchain()` fn; it calls `rzup::Rzup::new()` which
# reads $HOME/.risc0/ for toolchains, NOT rustup. The `.rzup` sentinel is
# checked by older risc0-build versions; harmless to leave.
#
# IMPORTANT: rzup's Paths::find_version_dir_inner (paths.rs:37) explicitly
# filters out entries that are symlinks:
#     entry.path().is_dir() && !entry.metadata().unwrap().is_symlink()
# So `ln -s /petros/opt/risc0 ...` gets ignored and build.rs panics with
# "Risc Zero Rust toolchain not found". rzup only inspects the top-level
# entries, not what's inside, so we make the toolchain dir a REAL mkdir'd
# directory and populate it with symlinks into /petros/opt/risc0/. Disk
# cost: ~4 KB of symlink entries; the 1.5 GB toolchain stays in /nix/store
# via buildEnv's existing symlinks.
RUN set -eux; \
  TC_DIR="$HOME/.risc0/toolchains/v${RISC0_TOOLCHAIN_VERSION}-rust-x86_64-unknown-linux-gnu"; \
  mkdir -p "$TC_DIR"; \
  ln -s /petros/opt/risc0/bin "$TC_DIR/bin"; \
  ln -s /petros/opt/risc0/lib "$TC_DIR/lib"; \
  : > "$HOME/.risc0/.rzup"

# Expose the RISC Zero CPP cross-toolchain in the rzup-compatible layout.
# Mirror of the rust block above. rzup's CppToolchain resolver (paths.rs)
# wants $HOME/.risc0/toolchains/v<VER>-cpp-<TARGET>/, and notes that "the
# C++ archive has a child directory we want to ignore", i.e. the inner
# `riscv32im-linux-x86_64/` dir produced by the upstream tarball.
#
# Two rzup gotchas to handle here:
#
# 1. The version-dir filename uses the *normalized* YYYY.M.D form (leading
#    zeros stripped from month and day), e.g. `v2024.1.5-cpp-...`, not
#    `v2024.01.05-cpp-...`. rzup's `parse_cpp_version` normalises on
#    install and `find_version_dir_inner` matches against the normalised
#    form on resolve. We awk-strip leading zeros from the env var and
#    use the result for both the directory name and the settings.toml
#    entry.
#
# 2. Same rzup-doesn't-follow-symlinks gotcha as the rust block, applied
#    at BOTH levels: both `v<VER>-cpp-<TARGET>/` AND the inner
#    `riscv32im-linux-x86_64/` MUST be real `mkdir`'d directories.
#    rzup's `find_version_dir_inner` filters out symlinked entries at
#    every descent, not just the top level. We mkdir both and only
#    symlink the leaf contents (bin/lib/libexec/...) pointing back at
#    /petros/opt/.
#
# Combines the rust-side settings.toml write (rust default version) and
# the cpp-side one into a single RUN so CPP_VER_NORM only has to be
# computed once.
RUN set -eux; \
  CPP_VER_NORM=$(echo "$RISC0_CPP_TOOLCHAIN_VERSION" \
    | awk -F. '{printf "%d.%d.%d", $1, $2, $3}'); \
  CPP_DIR="$HOME/.risc0/toolchains/v${CPP_VER_NORM}-cpp-x86_64-unknown-linux-gnu"; \
  INNER="$CPP_DIR/riscv32im-linux-x86_64"; \
  mkdir -p "$INNER"; \
  for entry in /petros/opt/risc0-cpp/riscv32im-linux-x86_64/*; do \
    ln -s "$entry" "$INNER/$(basename "$entry")"; \
  done; \
  printf '[default_versions]\nrust = "%s"\ncpp = "%s"\n' \
    "$RISC0_TOOLCHAIN_VERSION" "$CPP_VER_NORM" \
    > "$HOME/.risc0/settings.toml"

# Prepare wrapper scripts and shim for managing Rust toolchains. The wrappers
# handle the +toolchain syntax and this shim routes `cargo prove` to the
# Succinct toolchain. RISC Zero does not need an analogous shim: standard
# risc0 host crates invoke `risc0-build` from their own build.rs, which
# discovers the toolchain via the rzup layout above.
COPY src/scripts/wrapped_rustc.sh "$CARGO_HOME/bin/rustc"
COPY src/scripts/wrapped_cargo.sh "$CARGO_HOME/bin/cargo"
COPY src/scripts/sp1_shim.sh "$HOME/.sp1-shims/bin/cargo-prove"

# The `cargo +<toolchain>` spelling openvm-build emits resolves through
# wrapped_cargo above; verify it end-to-end now that the wrapper is in
# place. Same for the provisioning CLI: cargo-openvm's clap tree is rooted
# at `bin_name = "cargo"`, so it only answers when invoked as a cargo
# subcommand (`cargo openvm ...`), never bare.
RUN cargo "+${OPENVM_RUST_TOOLCHAIN}" --version
RUN cargo openvm --version

CMD ["bash"]
