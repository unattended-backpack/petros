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

  outputs = inputs@{ self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [];
    };

    # Install the SP1 CLI.
    sp1_cli = pkgs.stdenvNoCC.mkDerivation {
      pname = "sp1-cli";
      version = "5.2.1";
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
      version = "succinct-1.88.0";
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

          rustup_min

          # GnuPG without TPM support (avoids swtpm build failures).
          gnupg_notpm
        ];
      };

      default = self.outputs.packages.${system}.petros;
    };
  };
}
