/*
  Petros is a supply-chain hardened build environment.

  This flake creates a self-contained environment with:
    - core dependencies and build tools.
    - a specific vendored Rust toolchain.
    - a specific vendored SP1 ZKVM.
    - attic for Nix binary caching.

  All dependencies are vendored and cached via self-hosted attic.
*/
{
  inputs.nixpkgs.url = "path:/nixpkgs";
  inputs.sp1-cli.url = "path:/build/src/sp1/sp1-cli";
  inputs.sp1-cli.flake = false;
  inputs.sp1-tc.url = "path:/build/src/sp1/sp1-tc";
  inputs.sp1-tc.flake = false;
  inputs.sp1-plonk-vk.url = "path:/build/src/sp1/plonk-vk";
  inputs.sp1-plonk-vk.flake = false;
  inputs.risc0-tc.url = "path:/build/src/risc0/risc0-tc";
  inputs.risc0-tc.flake = false;
  inputs.risc0-cpp-tc.url = "path:/build/src/risc0/risc0-cpp-tc";
  inputs.risc0-cpp-tc.flake = false;
  inputs.openvm-tc.url = "path:/build/src/openvm/openvm-tc";
  inputs.openvm-tc.flake = false;
  inputs.openvm-cli.url = "path:/build/src/openvm/openvm-cli";
  inputs.openvm-cli.flake = false;

  # Verification tooling + ceremony artifacts (consumed by the unified
  # trusted-setup verification, `make verify-trusted-setup` downstream).
  inputs.circom.url = "path:/build/src/circom";
  inputs.circom.flake = false;
  inputs.snarkjs.url = "path:/build/src/snarkjs";
  inputs.snarkjs.flake = false;
  inputs.risc0-groth16.url = "path:/build/src/risc0-groth16";
  inputs.risc0-groth16.flake = false;
  inputs.ignition.url = "path:/build/src/ignition";
  inputs.ignition.flake = false;
  inputs.openvm-kzg.url = "path:/build/src/openvm/kzg";
  inputs.openvm-kzg.flake = false;
  inputs.solc.url = "path:/build/src/solidity/solc";
  inputs.solc.flake = false;
  inputs.openvm-verifier-pin.url = "path:/build/src/openvm/verifier-pin";
  inputs.openvm-verifier-pin.flake = false;
  inputs.ppot.url = "path:/build/src/ppot";
  inputs.ppot.flake = false;
  inputs.ethereum-kzg.url = "path:/build/src/ethereum-kzg";
  inputs.ethereum-kzg.flake = false;

  outputs = inputs@{ self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [];
      # NVIDIA CUDA redistributables ship under NVIDIA's proprietary EULA,
      # which nixpkgs classifies as "unfree" and refuses to evaluate by
      # default. Opt in *only* for packages whose license shortName is
      # "CUDA EULA" (both `nvidiaCuda` and `nvidiaCudaRedist` in
      # lib/licenses.nix use that exact label) so petros can consume
      # cudaPackages_12_9 without widening the door to arbitrary unfree
      # packages. The explicit `paths` list below is the ultimate allowlist
      # for what lands in the image anyway; this predicate just unblocks
      # evaluation of the CUDA closure.
      config.allowUnfreePredicate =
        pkg:
        let
          licenses =
            if builtins.isList (pkg.meta.license or null) then
              pkg.meta.license
            else
              [ (pkg.meta.license or { shortName = ""; }) ];
        in
        builtins.all (lic: (lic.shortName or "") == "CUDA EULA") licenses;
    };

    # Install the SP1 CLI.
    sp1_cli = pkgs.stdenvNoCC.mkDerivation {
      pname = "sp1-cli";
      version = "6.2.2";
      src = inputs."sp1-cli";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.glibc
        pkgs.stdenv.cc.cc
        pkgs.openssl
        pkgs.zlib
        pkgs.lz4
        pkgs.snappy
        pkgs.zstd
      ];
      dontStrip = true;
      installPhase = ''
        set -euo pipefail

        # Find the cargo-prove binary.
        bin=$(find "$src" -maxdepth 3 -type f \
          \( -name 'cargo-prove' -o -name 'cargo_prove' \) \
          | head -n1)

        if [ -z "$bin" ]; then
          echo "ERROR: cargo-prove binary not found" >&2
          find "$src" -maxdepth 3 | head -n 50 >&2
          exit 1
        fi

        mkdir -p "$out/bin"
        install -m755 "$bin" "$out/bin/cargo-prove"
      '';
    };

    # Install the SP1 custom Rust toolchain with RISC-V target support.
    sp1_tc = pkgs.stdenvNoCC.mkDerivation {
      pname = "sp1-tc";
      version = "succinct-1.93.0";
      src = inputs."sp1-tc";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.glibc
        pkgs.stdenv.cc.cc
        pkgs.openssl
        pkgs.zlib
      ];
      dontStrip = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/opt/succinct"
        cp -r "$src"/* "$out/opt/succinct/"
      '';
    };

    # Install the RISC Zero custom Rust toolchain. The risc0 toolchain ships
    # with the `riscv32im-risc0-zkvm-elf` target, which host crates using
    # risc0-build's build.rs pattern cross-compile their guest code to. We
    # intentionally don't vendor cargo-risczero: it hardcodes a Docker-based
    # guest build, and the underlying risc0-build library is usable directly
    # via a host crate's build.rs with `GuestOptions { use_docker: None, .. }`.
    risc0_tc = pkgs.stdenvNoCC.mkDerivation {
      pname = "risc0-tc";
      version = "r0-1.94.1";
      src = inputs."risc0-tc";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.glibc
        pkgs.stdenv.cc.cc
        pkgs.openssl
        pkgs.zlib
      ];
      dontStrip = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/opt/risc0"
        cp -r "$src"/* "$out/opt/risc0/"
      '';
    };

    # Install the RISC Zero CPP cross-toolchain. The upstream tarball
    # (`riscv32im-linux-x86_64.tar.xz`) expands to a top-level
    # `riscv32im-linux-x86_64/` directory containing the riscv32im-unknown-elf
    # gcc/g++ + binutils + sysroot. rzup looks for that nested directory
    # under `$HOME/.risc0/toolchains/v<VER>-cpp-<TARGET>/` and the Dockerfile
    # symlinks it across, so we preserve the inner directory verbatim in the
    # `$out/opt/risc0-cpp/` install prefix. autoPatchelfHook fixes up the
    # interpreter / RPATH of the host-side x86_64 binaries; the cross
    # toolchain's riscv32im output stays untouched because it's not ELF-
    # loadable on the host.
    risc0_cpp_tc = pkgs.stdenvNoCC.mkDerivation {
      pname = "risc0-cpp-tc";
      version = "r0-cpp-2024.01.05";
      src = inputs."risc0-cpp-tc";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.glibc
        pkgs.stdenv.cc.cc
        pkgs.zlib
        # GCC's multi-precision arithmetic libs: cc1 / cc1plus / lto1 /
        # lto-dump dynamically link `libgmp.so.10`, `libmpfr.so.6`, and
        # `libmpc.so.3`. Without these in buildInputs, autoPatchelfHook
        # bails with "could not satisfy dependency".
        pkgs.gmp
        pkgs.mpfr
        pkgs.libmpc
      ];
      dontStrip = true;

      # Skip the default `patchShebangs` post-install pass. The vendored
      # nixpkgs 24.11's `patch-shebangs.sh` crashes with `update: unbound
      # variable` at line 121 when it traverses the cpp toolchain's
      # nested `lib/gcc/...` and `riscv32-unknown-elf/` subtrees; a
      # stdenv bug we shouldn't paper over by changing those subtrees.
      # We don't run any in-tree scripts from the bundle anyway: the
      # host-side binaries we care about are real ELFs (handled by
      # autoPatchelfHook a phase earlier) and the target-side `.o` / `.a`
      # files don't have shebangs by definition. The `risc0_tc` (rust
      # toolchain) derivation doesn't hit this because its tarball has
      # no nested cross subtree.
      dontPatchShebangs = true;

      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/opt/risc0-cpp"
        cp -r "$src"/* "$out/opt/risc0-cpp/"
      '';
    };

    # Install the OpenVM guest Rust toolchain. Unlike the SP1 and RISC Zero
    # custom toolchains, OpenVM v2 pins a *stock* upstream nightly
    # (nightly-2026-01-18) plus the rust-src component: openvm-build compiles
    # guest std from source via `-Z build-std`. The vendored tarball is the
    # tree a real `rustup toolchain install` produces, including the
    # `lib/rustlib/multirust-channel-manifest.toml` + `lib/rustlib/components`
    # install manifests, because openvm-build's preflight runs
    # `rustup component list --toolchain <tc>` and requires `rust-src
    # (installed)` in the output. rustup answers that offline only for a
    # toolchain that carries those manifests; a `rustup toolchain link`ed
    # custom toolchain fails the check (custom toolchains don't support
    # component operations). The Dockerfile materializes this under
    # $RUSTUP_HOME/toolchains/ with the official channel-triple name.
    openvm_tc = pkgs.stdenvNoCC.mkDerivation {
      pname = "openvm-tc";
      version = "nightly-2026-01-18";
      src = inputs."openvm-tc";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.glibc
        pkgs.stdenv.cc.cc
        pkgs.openssl
        pkgs.zlib
      ];
      dontStrip = true;

      # Skip patchShebangs: the rust-src component under lib/rustlib/src/rust
      # is a large source tree containing shell scripts we never execute from
      # inside the store (guest builds only read the .rs sources via
      # build-std). autoPatchelfHook has already fixed every host-side ELF a
      # phase earlier, and skipping the traversal avoids the vendored
      # nixpkgs 24.11 patch-shebangs.sh crash the risc0-cpp-tc derivation
      # documents.
      dontPatchShebangs = true;

      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/opt/openvm"
        cp -r "$src"/* "$out/opt/openvm/"
      '';
    };

    # Install the cargo-openvm CLI. OpenVM publishes no prebuilt CLI binaries
    # (upstream instructs `cargo install --git`), so the vendored tarball is a
    # binary built once from the pinned release tag in a controlled container
    # (rust:1.91-bookworm, matching upstream's MSRV; see
    # docs/VENDORING.md). Used by downstream provisioning to run
    # `cargo openvm setup` (aggregation keygen + EVM artifact staging), not by
    # guest builds; those go through the openvm-build library from a host
    # crate's build.rs, mirroring the risc0-build arrangement.
    openvm_cli = pkgs.stdenvNoCC.mkDerivation {
      pname = "cargo-openvm";
      version = "2.0.1";
      src = inputs."openvm-cli";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [
        pkgs.glibc
        pkgs.stdenv.cc.cc
        pkgs.openssl
        pkgs.zlib
      ];
      dontStrip = true;
      installPhase = ''
        set -euo pipefail

        # Find the cargo-openvm binary.
        bin=$(find "$src" -maxdepth 3 -type f -name 'cargo-openvm' | head -n1)

        if [ -z "$bin" ]; then
          echo "ERROR: cargo-openvm binary not found" >&2
          find "$src" -maxdepth 3 | head -n 50 >&2
          exit 1
        fi

        mkdir -p "$out/bin"
        install -m755 "$bin" "$out/bin/cargo-openvm"
      '';
    };

    # circom 2.2.2: pinned because the r1cs hash the RISC Zero Groth16 ceremony
    # check reproduces is circom-version-sensitive (nixos-24.11 ships 2.2.0). The
    # vendored upstream release binary is dynamically linked glibc, so
    # autoPatchelfHook fixes its interpreter + RPATH like the SP1/RISC Zero CLIs.
    circom = pkgs.stdenvNoCC.mkDerivation {
      pname = "circom";
      version = "2.2.2";
      src = inputs."circom";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [ pkgs.glibc pkgs.stdenv.cc.cc ];
      dontStrip = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/bin"
        install -m755 "$src/circom" "$out/bin/circom"
      '';
    };

    # snarkjs 0.7.6: pure JS, run through the vendored nodejs. We ship the
    # exact node_modules closure (vendored tarball) and a thin wrapper so
    # `snarkjs` is on PATH. Symlinks keep the wrapper derivation tiny; the
    # node_modules bytes live once in the input's store path.
    snarkjs = pkgs.runCommand "snarkjs" { } ''
      set -euo pipefail
      mkdir -p "$out/bin"
      ln -s "${inputs."snarkjs"}/node_modules" "$out/node_modules"
      # snarkjs has no --version/version of its own (it answers "Invalid
      # command" and exits non-zero), so the wrapper supplies one from the
      # vendored package.json. Keeps it well-behaved for the smoke test.
      # printf (not an indented heredoc) so the shebang lands at column 0.
      ver=$(${pkgs.jq}/bin/jq -r .version \
        "${inputs."snarkjs"}/node_modules/snarkjs/package.json")
      printf '#!/bin/sh\ncase "$1" in --version|-v|version) echo "snarkjs@%s"; exit 0 ;; esac\n' \
        "$ver" > "$out/bin/snarkjs"
      printf 'exec %s/bin/node %s/node_modules/snarkjs/build/cli.cjs "$@"\n' \
        "${pkgs.nodejs}" "$out" >> "$out/bin/snarkjs"
      chmod +x "$out/bin/snarkjs"
    '';

    # RISC Zero Groth16 ceremony artifacts (ptau, zkey, circom sources,
    # control_id.rs) that the verification reads. Data, not executables, so we
    # park them under share/. Symlinks into the input store path so this
    # derivation stays a few KB and the ~13 GB lives once in the input.
    risc0_groth16_artifacts = pkgs.runCommand "risc0-groth16-artifacts" { } ''
      set -euo pipefail
      mkdir -p "$out/share/risc0-groth16"
      for f in ${inputs."risc0-groth16"}/*; do
        ln -s "$f" "$out/share/risc0-groth16/$(basename "$f")"
      done
    '';

    # OpenVM KZG params (kzg_bn254_{10..24}.srs), the PSE-halo2-format SRS set
    # that openvm's EVM (halo2-wrapped) prover consumes from ~/.openvm/params/.
    # Converted upstream from Perpetual Powers of Tau challenge_0085; the
    # OpenVM trusted-setup verification checks internal consistency offline
    # and documents the full ceremony re-derivation (see
    # docs/OPENVM_TRUSTED_SETUP.md). Data, not executables, so they park
    # under share/. Symlinks into the input store path keep this derivation
    # tiny; the ~4.1 GB lives once in the input.
    openvm_kzg_artifacts = pkgs.runCommand "openvm-kzg-artifacts" { } ''
      set -euo pipefail
      mkdir -p "$out/share/openvm-kzg"
      for f in ${inputs."openvm-kzg"}/*; do
        ln -s "$f" "$out/share/openvm-kzg/$(basename "$f")"
      done
    '';

    # solc binary (v0.8.19, the exact release the openvm-generated
    # verifier contracts pin). openvm-sdk's EVM verifier emission shells
    # out to `solc` on PATH during `cargo openvm setup --evm`; nixpkgs
    # 24.11 ships 0.8.21, which refuses the exact-pinned pragma, hence
    # the vendored official release build. Despite the upstream
    # "solc-static-linux" name it is a glibc-linked PIE (PT_INTERP
    # /lib64/ld-linux-x86-64.so.2), so autoPatchelfHook fixes its
    # interpreter + RPATH like circom and the SP1/RISC Zero CLIs.
    solc_bin = pkgs.stdenvNoCC.mkDerivation {
      pname = "solc-bin";
      version = "0.8.19";
      src = inputs."solc";
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      buildInputs = [ pkgs.glibc pkgs.stdenv.cc.cc ];
      dontStrip = true;
      installPhase = ''
        set -euo pipefail
        mkdir -p "$out/bin"
        install -m755 "$src/solc" "$out/bin/solc"
      '';
    };

    # OpenVM EVM-verifier content pin (verifier.expected-hashes): hashes
    # of the verifier Solidity + bytecode emitted by the one-time
    # `cargo openvm setup --evm` reproduction (see
    # docs/OPENVM_TRUSTED_SETUP.md). Staged under share/ so the
    # downstream sacristy `verify-bindings` goal can compare its
    # vendored, deployable contracts against it offline. Until the
    # reproduction has been run for the pinned OPENVM_VERSION the file
    # holds only comments and the downstream check fails closed.
    openvm_verifier_pin = pkgs.runCommand "openvm-verifier-pin" { } ''
      mkdir -p "$out/share/openvm"
      ln -s "${inputs."openvm-verifier-pin"}/verifier.expected-hashes" \
        "$out/share/openvm/verifier.expected-hashes"
      ln -s "${inputs."openvm-verifier-pin"}/halo2.pk.sha256" \
        "$out/share/openvm/halo2.pk.sha256"
    '';

    # SP1 PLONK Aztec Ignition offline bundle (the ~28 KB of first-power points +
    # pubkeys the chain check consumes, so the verification needs no S3 fetch)
    # plus the ceremony identity anchors: the participant manifest and the
    # per-transcript ECDSA signature tree scraped from the live bucket.
    ignition_bundle = pkgs.runCommand "ignition-bundle" { } ''
      set -euo pipefail
      mkdir -p "$out/share/ignition"
      for f in ${inputs."ignition"}/*; do
        ln -s "$f" "$out/share/ignition/$(basename "$f")"
      done
    '';

    # Perpetual Powers of Tau chain evidence: the full 67-record contribution
    # chain (nopoints), the independent ppot_0080 record extraction, raw-mirror
    # cross-bind slices for contribution 84 / challenge_0085, the ceremony
    # repo bundle (attestations + identity), and archival metadata. Phase-1
    # provenance for BOTH the RISC Zero Hermez ptau (records 1..54 + beacon)
    # and the OpenVM SRS (state after contribution 84). See
    # docs/CEREMONY_ANCHORS.md.
    ppot_artifacts = pkgs.runCommand "ppot-artifacts" { } ''
      set -euo pipefail
      mkdir -p "$out/share/ppot"
      for f in ${inputs."ppot"}/*; do
        ln -s "$f" "$out/share/ppot/$(basename "$f")"
      done
    '';

    # Ethereum KZG Summoning Ceremony: the full 141,417-contribution
    # transcript and the derived trusted_setup_4096.json whose
    # g2_monomial[1] equals the [tau]_2 constant in Sigil's L2
    # point-evaluation precompile.
    ethereum_kzg_artifacts = pkgs.runCommand "ethereum-kzg-artifacts" { } ''
      set -euo pipefail
      mkdir -p "$out/share/ethereum-kzg"
      for f in ${inputs."ethereum-kzg"}/*; do
        ln -s "$f" "$out/share/ethereum-kzg/$(basename "$f")"
      done
    '';

    # SP1 PLONK verification key (from sp1-verifier 6.2.2). sha256(plonk_vk.bin)
    # is the on-chain SP1VerifierPlonk VERIFIER_HASH the verification recomputes.
    sp1_plonk_vk = pkgs.runCommand "sp1-plonk-vk" { } ''
      set -euo pipefail
      mkdir -p "$out/share/sp1"
      ln -s "${inputs."sp1-plonk-vk"}/plonk_vk.bin" "$out/share/sp1/plonk_vk.bin"
    '';

    # Install the minimal rustup binary.
    rustup_min = pkgs.runCommand "rustup-min" {} ''
      mkdir -p $out/bin
      ln -s ${pkgs.rustup}/bin/rustup $out/bin/rustup
    '';

    # Install gnupg without TPM support to avoid swtpm build failures.
    gnupg_notpm = pkgs.gnupg.override {
      withTpm2Tss = false;
    };
  in {
    packages.${system} = {
      petros = pkgs.buildEnv {
        name = "petros-env";
        # CUDA redistributables each ship a top-level /LICENSE file under
        # their store path (different bytes per package; each is the
        # NVIDIA EULA as it pertains to that specific component). When
        # buildEnv unions store paths as symlinks, those collide. There's
        # no sane merge; accept that one of the LICENSE files wins and
        # move on. License text is identical in intent across the CUDA
        # redists, so the loss is cosmetic, and the packages' own store
        # paths (reachable via /nix/store/... directly) preserve the
        # original LICENSE files verbatim for compliance purposes.
        ignoreCollisions = true;
        # Pull multi-output CUDA (and other) packages' non-default outputs
        # so buildEnv links *all* the files downstream Rust builds need.
        # cuda_cudart specifically ships as five outputs:
        #   out:    metadata (small).
        #   dev:    headers (cuda_runtime.h etc).
        #   lib:    the dynamic libraries (libcudart.so.12*).
        #   static: static archives (libcudart_static.a, libcudadevrt.a).
        #   stubs:  driver-symbol stubs nvcc links against at build time
        #            (actual symbols come from the driver at runtime).
        # Without explicitly pulling lib + stubs, /petros/lib ends up with
        # only static archives, and nvcc/cc-rs/find_cuda_helper all fail to
        # locate libcudart. Listing "dev lib static stubs" covers every
        # file kind a CUDA-aware Rust build (sppark, cust_raw, risc0-sys)
        # needs during compile + link.
        extraOutputsToInstall = [ "dev" "lib" "static" "stubs" ];
        paths = with pkgs; [
          bash coreutils git cacert curl jq gnumake m4 file perl
          clang lld llvmPackages.libclang.lib pkg-config protobuf go
          openssl openssl.dev zlib zlib.dev lz4 lz4.dev snappy zstd zstd.dev
          attic-client
          attic-server
          nodejs
          docker-client
          doctl
          cosign
          crane

          # GNU tar: export.sh packs the runtime-image chunks with
          # --sort=name for deterministic, layer-cacheable tarballs
          # (busybox tar has no ordering knob). Shipping it in the env
          # also gives image users a full tar where PATH prefers
          # /petros/bin over busybox.
          gnutar

          # xz: busybox provides gzip but no xz applet, and downstream
          # hierophant builds extract the vendored rzup risc0-groth16
          # component (a .tar.xz) inside this image; tar spawns xz as a
          # child and fails without it on PATH.
          xz

          # Vendored Rust 1.93.1 toolchain.
          rust_1_93.packages.stable.rustc
          rust_1_93.packages.stable.cargo

          # Vendored SP1.
          sp1_cli
          sp1_tc

          # Vendored RISC Zero toolchain (no CLI; builds go through
          # risc0-build invoked by a host crate's build.rs).
          risc0_tc

          # Vendored RISC Zero CPP cross-toolchain. risc0-zkvm's guest
          # crate's build.rs cross-compiles its C/C++ syscall-stub layer
          # into the guest ELF using the riscv32im-unknown-elf gcc/g++ from
          # here. The Dockerfile symlinks /petros/opt/risc0-cpp into the
          # rzup-compatible layout under $HOME/.risc0/toolchains/. This is
          # the only zkVM C toolchain Petros ships: the SP1 guest is pure
          # Rust (Sigil routes its crypto through k256 and keeps zstd
          # host-only), so it needs no C cross-compiler.
          risc0_cpp_tc

          # Vendored OpenVM guest toolchain (stock nightly-2026-01-18 +
          # rust-src) and the cargo-openvm provisioning CLI. The Dockerfile
          # materializes the toolchain under $RUSTUP_HOME/toolchains/ with
          # its official channel-triple name so openvm-build's rustup
          # component preflight passes offline.
          openvm_tc
          openvm_cli

          # Trusted-setup verification: pinned circom + snarkjs tooling and the
          # RISC Zero Groth16 ceremony artifacts, all consumed offline by
          # `make verify-trusted-setup` downstream (no runtime downloads).
          circom
          snarkjs
          risc0_groth16_artifacts
          ignition_bundle
          sp1_plonk_vk
          openvm_kzg_artifacts
          solc_bin
          openvm_verifier_pin
          ppot_artifacts
          ethereum_kzg_artifacts

          rustup_min

          # GnuPG without TPM support (avoids swtpm build failures).
          gnupg_notpm

          # CUDA 12.9.1: the three redistributable components risc0-sys +
          # sppark actually need. Backported into the vendored nixpkgs (see
          # src/nixpkgs/pkgs/development/cuda-modules/) because nixos-24.11
          # shipped with CUDA 12.4 as the newest, and we need 12.9 specifically
          # for native Blackwell-consumer (sm_120) support so RTX 5090 slaves
          # can run risc0 CUDA proofs without PTX JIT. The 12.9.1 manifest
          # JSONs were cherry-picked from nixpkgs master at commit d3802543
          # (PR #405286). Bump in lockstep with risc0-zkvm only when that crate
          # ships a newer sppark that supports CUDA 13+.
          #
          # We pull the individual components instead of the `cudatoolkit`
          # meta-package on purpose: cudatoolkit drags in cuda_gdb, cuda_nsight,
          # samples, and docs, which carry runtime deps (ncurses, tinfo, the
          # full set of pythons, libcrypt) that petros's minimal build env
          # doesn't satisfy and that we don't need for compiling proving
          # kernels anyway.
          #   cuda_nvcc:   compiler, ptxas, nvdisasm, related binaries
          #   cuda_cudart: runtime library + headers (cuda_runtime.h etc)
          #   cuda_cccl:  CUDA C++ Core Libraries template headers
          cudaPackages_12_9.cuda_nvcc
          cudaPackages_12_9.cuda_cudart
          cudaPackages_12_9.cuda_cccl
        ];
      };

      # Chunk roots for export.sh's classed store partition: tiny
      # buildEnvs over derivations already inside `petros`, so each
      # closure is a subset of the main closure by construction (the
      # export intersects against the main closure regardless). The
      # runtime stage imports one chunk per docker layer, keyed on
      # content digest; see src/scripts/export.sh for the partition
      # rules and the stability ordering. extraOutputsToInstall mirrors
      # the main env so multi-output packages are claimed whole.
      chunk-ceremony = pkgs.buildEnv {
        name = "chunk-ceremony";
        ignoreCollisions = true;
        extraOutputsToInstall = [ "dev" "lib" "static" "stubs" ];
        paths = [
          risc0_groth16_artifacts
          openvm_kzg_artifacts
          ppot_artifacts
          ethereum_kzg_artifacts
        ];
      };
      chunk-cuda = pkgs.buildEnv {
        name = "chunk-cuda";
        ignoreCollisions = true;
        extraOutputsToInstall = [ "dev" "lib" "static" "stubs" ];
        paths = with pkgs; [
          cudaPackages_12_9.cuda_nvcc
          cudaPackages_12_9.cuda_cudart
          cudaPackages_12_9.cuda_cccl
        ];
      };
      chunk-compilers = pkgs.buildEnv {
        name = "chunk-compilers";
        ignoreCollisions = true;
        extraOutputsToInstall = [ "dev" "lib" "static" "stubs" ];
        paths = with pkgs; [
          rust_1_93.packages.stable.rustc
          rust_1_93.packages.stable.cargo
          clang
          lld
          llvmPackages.libclang.lib
          go
        ];
      };
      chunk-zkvm = pkgs.buildEnv {
        name = "chunk-zkvm";
        ignoreCollisions = true;
        extraOutputsToInstall = [ "dev" "lib" "static" "stubs" ];
        paths = [
          sp1_cli
          sp1_tc
          risc0_tc
          risc0_cpp_tc
          openvm_tc
          openvm_cli
        ];
      };

      default = self.outputs.packages.${system}.petros;
    };
  };
}
