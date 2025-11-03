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

# Download vendored dependencies from self-hosted source.
# This script verifies that checksums match.
COPY src/nix/nix.sha256 /tmp/
COPY src/attic/attic-store.tar.gz.sha256 /tmp/
COPY src/sp1/ /tmp/
RUN /build/src/scripts/vendor.sh

# Install static Nix.
RUN mv /tmp/nix /usr/local/bin/nix \
  && chmod +x /usr/local/bin/nix \
  && rm /tmp/nix.sha256

# Prepare the statically-vendored Nix with store and build users.
RUN mkdir -p /nix/store /nix/var/nix/profiles/per-user/root; \
 addgroup -S nixbld; \
 for i in $(seq 0 31); do adduser -S -D -H -G nixbld nixbld$i; done

# Extract vendored attic binaries before using private substituters.
# This solves the chicken-and-egg problem of needing attic to authenticate
# against the private cache, but needing the cache to get attic.
COPY src/attic/attic-client.outpath /tmp/
COPY src/attic/attic-server.outpath /tmp/
RUN tar -C / -xzf /tmp/attic-store.tar.gz \
  && ATTIC_CLIENT=$(cat /tmp/attic-client.outpath) \
  && ATTIC_SERVER=$(cat /tmp/attic-server.outpath) \
  && ln -s $ATTIC_CLIENT/bin/attic /usr/local/bin/attic \
  && ln -s $ATTIC_SERVER/bin/atticadm /usr/local/bin/atticadm \
  && rm /tmp/attic-store.tar.gz /tmp/attic-store.tar.gz.sha256 \
     /tmp/attic-client.outpath /tmp/attic-server.outpath

# Validate that the `ATTIC_SERVER_URL` is accessible.
RUN curl --fail --silent --show-error \
  --max-time 10 --retry 0 "${ATTIC_SERVER_URL}" > /dev/null || ( \
    echo "ERROR: ATTIC_SERVER_URL '${ATTIC_SERVER_URL}' is unreachable!" >&2 \
    && exit 1)

# Extract vendored SP1 tarballs to directories for `flake.nix` PATH URLs.
RUN mkdir -p /build/src/sp1/sp1-cli && \
  tar -xzf /tmp/cargo_prove_v5.2.1_linux_amd64.tar.gz \
    -C /build/src/sp1/sp1-cli/ && \
  rm /tmp/cargo_prove_v5.2.1_linux_amd64.tar.gz \
     /tmp/cargo_prove_v5.2.1_linux_amd64.tar.gz.sha256
RUN mkdir -p /build/src/sp1/sp1-tc && \
  tar -xzf /tmp/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
    -C /build/src/sp1/sp1-tc/ && \
  rm /tmp/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz \
     /tmp/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz.sha256

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
USER 10001:10001

# Test that all expected binaries are working.
COPY src/scripts/test.sh /home/petros/test.sh
RUN sh /home/petros/test.sh bash ls cat echo openssl curl jq gpg \
  pkg-config rustc cargo node docker doctl cosign make && \
  rm /home/petros/test.sh
RUN which cargo-prove
RUN cargo prove --version
RUN attic --version
RUN atticadm --version
RUN cosign version

# Link the Succinct toolchain into `rustup`.
RUN mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
  rustup toolchain link succinct /petros/opt/succinct; \
  rustup toolchain list

# Prepare wrapper scripts and shim for managing Rust toolchains. The wrappers
# handle the +toolchain syntax and this shim routes `cargo prove` to the
# Succinct toolchain.
COPY src/scripts/wrapped_rustc.sh "$CARGO_HOME/bin/rustc"
COPY src/scripts/wrapped_cargo.sh "$CARGO_HOME/bin/cargo"
COPY src/scripts/sp1_shim.sh "$HOME/.sp1-shims/bin/cargo-prove"
CMD ["bash"]
