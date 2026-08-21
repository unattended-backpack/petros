# Bumping a Vendored Dependency

Petros vendors four classes of external binary dependencies so that any historical commit can be rebuilt byte-identically against exactly the bytes it was tested with. Each vendored asset lives at two places:

- A committed sha256 checksum file under `src/<kind>/<version>/` in this repository.
- The matching tarball or binary at `${VENDOR_BASE_URL}/<kind>/<version>/` on the CDN.

Pointers to which version of each is active live in [`.env.maintainer`](../.env.maintainer) as the `SP1_VERSION`, `RISC0_TOOLCHAIN_VERSION`, `OPENVM_VERSION`, `OPENVM_KZG_VERSION`, `ATTIC_VERSION`, and `NIX_VERSION` variables. Bumping any one of them follows the same general procedure documented below, with kind-specific notes after.

## General Procedure

1. **Obtain the new upstream artifact** from whoever publishes it. See the per-class notes below for where each one lives.
2. **Compute its sha256**:
   ```bash
   sha256sum <file> > <file>.sha256
   ```
3. **Upload the artifact to the CDN** at the path layout this kind expects. The Dockerfile expects every vendored tarball to live at `${VENDOR_BASE_URL}/<kind>/<version>/<file>`.
4. **Commit the checksum file** under `src/<kind>/<new-version>/<file>.sha256`. The tarball itself is not committed; only its sha256.
5. **Bump the corresponding variable** in `.env.maintainer` to `<new-version>`.
6. **Run `make build`** to verify the new version downloads, checksum-verifies, and integrates. You should end up with a working Petros image.

Old entries under `src/<kind>/<old-version>/` can be left in place. They are not consumed at build time unless `.env.maintainer` is rolled back; keeping them around makes older Petros commits reproducible.

## Per-Class Notes

### `SP1_VERSION`

Drives vendoring of two tarballs:

- `cargo_prove_<SP1_VERSION>_linux_amd64.tar.gz` contains the `cargo-prove` CLI.
- `rust-toolchain-x86_64-unknown-linux-gnu.tar.gz` contains the Succinct-custom Rust toolchain that `cargo-prove` dispatches to.

Both ship as part of a matched Succinct SP1 release. Obtain them from the upstream release, compute sha256s, upload to `${VENDOR_BASE_URL}/sp1/<SP1_VERSION>/`, and commit both `.sha256` files under `src/sp1/<SP1_VERSION>/`.

Bump this in lockstep with any downstream bump of `sp1-sdk` that requires a new Succinct Rust toolchain.

### `RISC0_TOOLCHAIN_VERSION`

Drives vendoring of one tarball:

- `rust-toolchain-x86_64-unknown-linux-gnu.tar.gz` contains the RISC Zero custom Rust toolchain.

`RISC0_TOOLCHAIN_VERSION` is the same string that `rzup` stamps into its on-disk layout at `$HOME/.risc0/toolchains/v<VERSION>-rust-<target>/` and that `risc0-build` looks for at guest build time. The Dockerfile reproduces that layout by symlinking into the extracted tarball; see the runtime stage of [`Dockerfile`](../Dockerfile).

Obtain the tarball from the upstream RISC Zero toolchain release, upload to `${VENDOR_BASE_URL}/risc0/<RISC0_TOOLCHAIN_VERSION>/`, and commit the sha256 under `src/risc0/<RISC0_TOOLCHAIN_VERSION>/`.

Bump this in lockstep with any downstream bump of `risc0-zkvm` that requires a new toolchain.

### `OPENVM_VERSION`

Drives vendoring of two tarballs:

- `rust-toolchain-x86_64-unknown-linux-gnu.tar.gz` contains the stock upstream Rust nightly that openvm-build pins for guest builds, plus the `rust-src` component.
- `cargo-openvm_<OPENVM_VERSION>_linux_amd64.tar.gz` contains the `cargo-openvm` provisioning CLI.

Unlike SP1 and RISC Zero, neither ships as an upstream release artifact, so both are produced by the maintainer:

**Toolchain**: the tarball must be the tree a real `rustup toolchain install` writes, including `lib/rustlib/multirust-channel-manifest.toml` and `lib/rustlib/components`, because openvm-build's preflight queries `rustup component list` for `rust-src (installed)` and rustup can only answer offline from those install manifests. Produce it with:

```bash
export RUSTUP_HOME=$(mktemp -d)
rustup toolchain install <OPENVM_RUST_TOOLCHAIN> --profile minimal --component rust-src
tar -C "$RUSTUP_HOME/toolchains/<OPENVM_RUST_TOOLCHAIN>-x86_64-unknown-linux-gnu" \
  -czf rust-toolchain-x86_64-unknown-linux-gnu.tar.gz .
rm -rf "$RUSTUP_HOME"
```

The channel name (`OPENVM_RUST_TOOLCHAIN` in `.env.maintainer`) comes from openvm-build's `DEFAULT_RUSTUP_TOOLCHAIN_NAME`; check it whenever bumping `OPENVM_VERSION` and keep the two in lockstep.

**CLI**: OpenVM publishes no prebuilt binaries (upstream instructs `cargo install --git`). Build once from the pinned tag inside a container matching upstream's MSRV so the produced binary's glibc floor stays below every runtime petros supports:

```bash
docker run --rm -v "$PWD/out":/out rust:1.91-bookworm bash -c '
  apt-get update -qq && apt-get install -y -qq cmake golang-go
  export CARGO_HOME=/tmp/cargo
  cargo install --git https://github.com/openvm-org/openvm.git \
    --tag <OPENVM_VERSION> cargo-openvm --locked --root /out'
tar -C out/bin -czf cargo-openvm_<OPENVM_VERSION>_linux_amd64.tar.gz cargo-openvm
```

Upload both to `${VENDOR_BASE_URL}/openvm/<OPENVM_VERSION>/`, and commit both `.sha256` files under `src/openvm/<OPENVM_VERSION>/`. Bump in lockstep with any downstream bump of the `openvm-sdk` git tag.

### `OPENVM_KZG_VERSION`

Drives vendoring of the fifteen KZG params files `kzg_bn254_10.srs` through `kzg_bn254_24.srs`: the PSE-halo2-format SRS set that openvm's EVM (halo2-wrapped) prover consumes from `~/.openvm/params/` and that `cargo openvm setup` would otherwise download from openvm's upstream S3.

The version string names the Perpetual Powers of Tau contribution the set derives from (`challenge_0085` for OpenVM v2). Obtain the files from openvm's upstream source (`s3://axiom-crypto/<OPENVM_KZG_VERSION>/kzg_bn254_<k>.srs`), or re-derive them from the ceremony transcript itself; see [`OPENVM_TRUSTED_SETUP.md`](./OPENVM_TRUSTED_SETUP.md) for the verification and re-derivation procedure. Upload to `${VENDOR_BASE_URL}/openvm/kzg/<OPENVM_KZG_VERSION>/` and commit one `.sha256` per file under `src/openvm/kzg/<OPENVM_KZG_VERSION>/`.

Only bump when OpenVM re-points its params source at a different ceremony contribution; re-run the trusted-setup verification whenever it changes.

### `ATTIC_VERSION`

Drives vendoring of the attic-client + attic-server Nix closure tarball:

- `attic-store.tar.gz` is the closure tarball.
- `attic-client.outpath` is a text file containing the `/nix/store/...` path of the attic client binary inside the closure.
- `attic-server.outpath` is the matching text file for the atticadm binary.

Produce all three with `src/scripts/bootstrap-attic.sh`. See [`BOOTSTRAP.md`](./BOOTSTRAP.md) for the full procedure. Upload the closure tarball to `${VENDOR_BASE_URL}/attic/<ATTIC_VERSION>/attic-store.tar.gz`, then commit the sha256 and both `.outpath` files under `src/attic/<ATTIC_VERSION>/`.

`<ATTIC_VERSION>` is conventionally the date suffix from the attic-client store path (for example, `unstable-2025-09-24`) so that the vendored closure tracks the upstream attic snapshot it was bootstrapped from.

### `NIX_VERSION`

Drives vendoring of the statically linked Nix binary:

- `nix` is the static `nix` binary itself.

Obtain the static release from the upstream Nix project or cross-compile it yourself. Upload to `${VENDOR_BASE_URL}/nix/<NIX_VERSION>/nix`, then commit the sha256 under `src/nix/<NIX_VERSION>/`.

This rarely needs to change. Only bump when the embedded static Nix fails against a newer flake or store CLI shape that downstream consumers use.

## Bumping CUDA Through the Vendored Nixpkgs

Petros carries a small patch series on top of its vendored `nixos-24.11` nixpkgs snapshot so that a CUDA version newer than nixos-24.11's native 12.4 can be consumed from the flake. The current patch set backports CUDA 12.9.1 from nixpkgs `master`.

The files touched are:

- `src/nixpkgs/pkgs/development/cuda-modules/cuda/manifests/feature_<ver>.json` and the matching `redistrib_<ver>.json` contain the redistributable component URLs and sha256s nixpkgs fetches.
- `src/nixpkgs/pkgs/development/cuda-modules/cuda/extension.nix` adds a short `<major>.<minor>` entry to `cudaVersionMap` pointing at the full `<major>.<minor>.<patch>` the manifests define.
- `src/nixpkgs/pkgs/development/cuda-modules/cuda/overrides.nix` relaxes the `nvcc.profile` substitution to cover the new CUDA version's format.
- `src/nixpkgs/pkgs/development/cuda-modules/nvcc-compatibilities.nix` adds an entry recording the maximum Clang and GCC versions the new CUDA version accepts as host compilers.
- `src/nixpkgs/pkgs/top-level/all-packages.nix` exposes the new `cudaPackages_<major>_<minor>` attribute at the top level of the pkgs set.

To bump to a future CUDA version (for example, when a downstream dependency supports CUDA 13):

1. **Locate the upstream PR** that introduced the new version into nixpkgs `master`. The 12.9.1 backport originated from PR #405286, commit `d3802543`.
2. **Cherry-pick the two manifest JSONs** into `src/nixpkgs/pkgs/development/cuda-modules/cuda/manifests/` verbatim. The manifests are self-contained and do not depend on the surrounding nixpkgs version.
3. **Register the new `cudaVersionMap` entry** in `extension.nix`.
4. **Register compiler compatibility** in `nvcc-compatibilities.nix` with the maximum Clang and GCC versions the new CUDA version accepts. These are documented in NVIDIA's release notes for the target version.
5. **Broaden the `nvcc.profile` patch** in `overrides.nix` if NVIDIA restructured the profile file between versions. The existing patch uses `--replace-quiet` so both the old and new formats can be handled from the same file.
6. **Expose the new package set** in `all-packages.nix` as `cudaPackages_<major>_<minor> = callPackage ./cuda-packages.nix { cudaVersion = "<major>.<minor>"; };`.
7. **Update `flake.nix`** to pull the new `cudaPackages_<major>_<minor>.{cuda_nvcc,cuda_cudart,cuda_cccl}` components into the environment, replacing the previous set.
8. **Rebuild and verify** with `make build`. The petros image should come out with the new `nvcc` on PATH and the new cudart library linked into downstream CUDA Rust builds.

Only bump CUDA when a downstream CUDA-using dependency actually requires a newer version. Keeping CUDA as conservative as possible minimizes the image size and the surface of NVIDIA binaries shipped in Petros.
