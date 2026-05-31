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
  inputs.risc0-tc.url = "path:/build/src/risc0/risc0-tc";
  inputs.risc0-tc.flake = false;
  inputs.risc0-cpp-tc.url = "path:/build/src/risc0/risc0-cpp-tc";
  inputs.risc0-cpp-tc.flake = false;

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
      # nested `lib/gcc/...` and `riscv32-unknown-elf/` subtrees — a
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
        # their store path (different bytes per package — each is the
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
        #   out    — metadata (small).
        #   dev    — headers (cuda_runtime.h etc).
        #   lib    — the dynamic libraries (libcudart.so.12*).
        #   static — static archives (libcudart_static.a, libcudadevrt.a).
        #   stubs  — driver-symbol stubs nvcc links against at build time
        #            (actual symbols come from the driver at runtime).
        # Without explicitly pulling lib + stubs, /petros/lib ends up with
        # only static archives, and nvcc/cc-rs/find_cuda_helper all fail to
        # locate libcudart. Listing "dev lib static stubs" covers every
        # file kind a CUDA-aware Rust build (sppark, cust_raw, risc0-sys)
        # needs during compile + link.
        extraOutputsToInstall = [ "dev" "lib" "static" "stubs" ];
        paths = with pkgs; [
          bash coreutils git cacert curl jq gnumake file perl
          clang lld llvmPackages.libclang.lib pkg-config protobuf go
          openssl openssl.dev zlib zlib.dev lz4 lz4.dev snappy zstd zstd.dev
          attic-client
          attic-server
          nodejs
          docker-client
          doctl
          cosign
          crane

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

          rustup_min

          # GnuPG without TPM support (avoids swtpm build failures).
          gnupg_notpm

          # CUDA 12.9.1 — the three redistributable components risc0-sys +
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
          #   cuda_nvcc   — compiler, ptxas, nvdisasm, related binaries
          #   cuda_cudart — runtime library + headers (cuda_runtime.h etc)
          #   cuda_cccl   — CUDA C++ Core Libraries template headers
          cudaPackages_12_9.cuda_nvcc
          cudaPackages_12_9.cuda_cudart
          cudaPackages_12_9.cuda_cccl
        ];
      };

      default = self.outputs.packages.${system}.petros;
    };
  };
}
