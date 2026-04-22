FROM alpine:3.20@sha256:765942a4039992336de8dd5db680586e1a206607dd06170ff0a37267a9e01958 AS builder

# Prepare environment variables from required arguments.
# Validate that the `ATTIC_SERVER_URL` is specified.
ARG ATTIC_SERVER_URL
RUN test -n "${ATTIC_SERVER_URL}" || ( \
  echo "ERROR: ATTIC_SERVER_URL build argument is required!" >&2 \
  && exit 1)
ENV ATTIC_SERVER_URL=${ATTIC_SERVER_URL}

# The `ATTIC_CACHE` must specify an available cache on the attic server.
ARG ATTIC_CACHE
RUN test -n "${ATTIC_CACHE}" || ( \
  echo "ERROR: ATTIC_CACHE build argument is required!" >&2 \
  && exit 1)
ENV ATTIC_CACHE=${ATTIC_CACHE}

# The `ATTIC_PUBLIC_KEY` must specify the public key of the attic server.
ARG ATTIC_PUBLIC_KEY
RUN test -n "${ATTIC_PUBLIC_KEY}" || ( \
  echo "ERROR: ATTIC_PUBLIC_KEY build argument is required!" >&2 \
  && exit 1)
ENV ATTIC_PUBLIC_KEY=${ATTIC_PUBLIC_KEY}

# The `VENDOR_BASE_URL` specifies where to download vendored dependencies.
ARG VENDOR_BASE_URL
RUN test -n "${VENDOR_BASE_URL}" || ( \
  echo "ERROR: VENDOR_BASE_URL build argument is required!" >&2 \
  && exit 1)
ENV VENDOR_BASE_URL=${VENDOR_BASE_URL}

# SP1 release that drives the path for both vendored SP1 assets (cargo-prove
# CLI + succinct rust toolchain). Tarballs live at
# ${VENDOR_BASE_URL}/sp1/${SP1_VERSION}/... with their sha256s committed at
# src/sp1/${SP1_VERSION}/.
ARG SP1_VERSION
RUN test -n "${SP1_VERSION}" || ( \
  echo "ERROR: SP1_VERSION build argument is required!" >&2 \
  && exit 1)
ENV SP1_VERSION=${SP1_VERSION}

# RISC Zero rust toolchain version — matches the directory name rzup uses
# under ~/.risc0/toolchains/v<VER>-rust-<target>/, and the path component on
# the vendor CDN under ${VENDOR_BASE_URL}/risc0/${RISC0_TOOLCHAIN_VERSION}/.
ARG RISC0_TOOLCHAIN_VERSION
RUN test -n "${RISC0_TOOLCHAIN_VERSION}" || ( \
  echo "ERROR: RISC0_TOOLCHAIN_VERSION build argument is required!" >&2 \
  && exit 1)
ENV RISC0_TOOLCHAIN_VERSION=${RISC0_TOOLCHAIN_VERSION}

# Upstream attic snapshot tag (from the `attic-*.outpath` nix store path
# suffix). Pins the attic-store closure + its two .outpath files.
ARG ATTIC_VERSION
RUN test -n "${ATTIC_VERSION}" || ( \
  echo "ERROR: ATTIC_VERSION build argument is required!" >&2 \
  && exit 1)
ENV ATTIC_VERSION=${ATTIC_VERSION}

# Upstream nix release whose static binary is vendored here.
ARG NIX_VERSION
RUN test -n "${NIX_VERSION}" || ( \
  echo "ERROR: NIX_VERSION build argument is required!" >&2 \
  && exit 1)
ENV NIX_VERSION=${NIX_VERSION}

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

# Download vendored dependencies from self-hosted source. Each asset's
# versioned subdir is COPYd into a matching /tmp/<asset>/ subdir so vendor.sh
# can place the two same-named rust-toolchain tarballs (SP1 + RISC Zero) and
# the two same-named sha256 scopes (nix + attic) without collision.
COPY src/nix/${NIX_VERSION}/ /tmp/nix/
COPY src/attic/${ATTIC_VERSION}/ /tmp/attic/
COPY src/sp1/${SP1_VERSION}/ /tmp/sp1/
COPY src/risc0/${RISC0_TOOLCHAIN_VERSION}/ /tmp/risc0/
RUN /build/src/scripts/vendor.sh

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

# Extract vendored RISC Zero toolchain to the path flake.nix points at.
RUN mkdir -p /build/src/risc0/risc0-tc && \
  tar -xzf /tmp/risc0/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
    -C /build/src/risc0/risc0-tc/ && \
  rm -rf /tmp/risc0/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
         /tmp/risc0/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz.sha256

# Register our vendored nixpkgs as the default
RUN nix registry add nixpkgs path:/nixpkgs
RUN nix flake metadata .

# Accept token hash to bust cache when token changes (without exposing secret).
ARG ATTIC_CACHE_BUST
RUN echo "Cache bust: ${ATTIC_CACHE_BUST}"

# Build and cache the complete Petros environment. The initial build may take a
# very long time depending on what is cached in attic.
RUN --mount=type=secret,id=attic_token \
  /build/src/scripts/build.sh path:/build#petros

# Prepare an export of packages for the final image.
# Export the entire Petros environment which includes all tools
RUN /build/src/scripts/export.sh path:/build#petros

# Petros is a final, minimal build image containing only our exported packages
# with Nix removed.
FROM alpine:3.20@sha256:765942a4039992336de8dd5db680586e1a206607dd06170ff0a37267a9e01958 AS petros

# Re-declare build-arg we need in the runtime stage — ARGs don't carry across
# stages. The rzup layout setup below interpolates this into the toolchain
# directory name rzup expects.
ARG RISC0_TOOLCHAIN_VERSION
RUN test -n "${RISC0_TOOLCHAIN_VERSION}" || ( \
  echo "ERROR: RISC0_TOOLCHAIN_VERSION build argument is required!" >&2 \
  && exit 1)
ENV RISC0_TOOLCHAIN_VERSION=${RISC0_TOOLCHAIN_VERSION}

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

# Copy the built and exported Nix store.
COPY --from=builder /export/store.tar /tmp/store.tar
COPY --from=builder /export/store.outpath /tmp/store.outpath

# Import the exported store and clean up afterwards.
COPY src/scripts/import.sh /tmp/import.sh
RUN sh /tmp/import.sh /tmp/store.tar /tmp/store.outpath && \
  rm /tmp/import.sh /tmp/store.outpath

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
  pkg-config rustc cargo node docker doctl cosign crane make file protoc go clang perl && \
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

# Expose the RISC Zero toolchain in the rzup-compatible layout that risc0-build
# (via the rzup crate) expects when resolving the rustc path. See
# risc0-build's `rust_toolchain()` fn — it calls `rzup::Rzup::new()` which
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
  : > "$HOME/.risc0/.rzup"; \
  printf '[default_versions]\nrust = "%s"\n' "$RISC0_TOOLCHAIN_VERSION" \
    > "$HOME/.risc0/settings.toml"

# Prepare wrapper scripts and shim for managing Rust toolchains. The wrappers
# handle the +toolchain syntax and this shim routes `cargo prove` to the
# Succinct toolchain. RISC Zero does not need an analogous shim: standard
# risc0 host crates invoke `risc0-build` from their own build.rs, which
# discovers the toolchain via the rzup layout above.
COPY src/scripts/wrapped_rustc.sh "$CARGO_HOME/bin/rustc"
COPY src/scripts/wrapped_cargo.sh "$CARGO_HOME/bin/cargo"
COPY src/scripts/sp1_shim.sh "$HOME/.sp1-shims/bin/cargo-prove"
CMD ["bash"]
