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
          bash coreutils git cacert curl jq
          clang lld pkg-config
          openssl zlib lz4 snappy zstd
          attic-client
          attic-server
          nodejs
          docker-client
          doctl
          cosign

          # Vendored Rust 1.89.0 toolchain.
          rust_1_89.packages.stable.rustc
          rust_1_89.packages.stable.cargo

          # Vendored SP1.
          sp1_cli
          sp1_tc
          rustup_min

          # GnuPG without TPM support (avoids swtpm build failures).
          gnupg_notpm
        ];
      };

      default = self.outputs.packages.${system}.petros;
    };
  };
}
