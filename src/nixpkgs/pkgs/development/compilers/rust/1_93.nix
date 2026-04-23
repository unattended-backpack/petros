# New rust versions should first go to staging.
# Things to check after updating:
# 1. Rustc should produce rust binaries on x86_64-linux, aarch64-linux and x86_64-darwin:
#    i.e. nix-shell -p fd or @GrahamcOfBorg build fd on github
#    This testing can be also done by other volunteers as part of the pull
#    request review, in case platforms cannot be covered.
# 2. The LLVM version used for building should match with rust upstream.
#    Check the version number in the src/llvm-project git submodule in:
#    https://github.com/rust-lang/rust/blob/<version-tag>/.gitmodules

{
  stdenv,
  lib,
  newScope,
  callPackage,
  CoreFoundation,
  Security,
  SystemConfiguration,
  pkgsBuildTarget,
  pkgsBuildBuild,
  pkgsBuildHost,
  pkgsHostTarget,
  pkgsTargetTarget,
  makeRustPlatform,
  wrapRustcWith,
  llvmPackages_21,
  llvm_21,
  wrapCCWith,
  overrideCC,
  fetchpatch,
}@args:
let
  llvmSharedFor =
    pkgSet:
    pkgSet.llvmPackages_21.libllvm.override (
      {
        enableSharedLibraries = true;
      }
      // lib.optionalAttrs (stdenv.targetPlatform.useLLVM or false) {
        # Force LLVM to compile using clang + LLVM libs when targeting pkgsLLVM
        stdenv = pkgSet.stdenv.override {
          allowedRequisites = null;
          cc = pkgSet.pkgsBuildHost.llvmPackages_21.clangUseLLVM;
        };
      }
    );
in
import ./default.nix
  {
    rustcVersion = "1.93.1";
    rustcSha256 = "sha256-TCMKRLPZyfPO+VCUNxn4OABY0nyR/aXjapqUfvAT4B8=";
    rustcPatches = [ ./ignore-missing-docs.patch ];

    llvmSharedForBuild = llvmSharedFor pkgsBuildBuild;
    llvmSharedForHost = llvmSharedFor pkgsBuildHost;
    llvmSharedForTarget = llvmSharedFor pkgsBuildTarget;

    llvmPackages = llvmPackages_21;

    # For use at runtime
    llvmShared = llvmSharedFor pkgsHostTarget;

    # Note: the version MUST be the same version that we are building. Upstream
    # ensures that each released compiler can compile itself:
    # https://github.com/NixOS/nixpkgs/pull/351028#issuecomment-2438244363
    bootstrapVersion = "1.93.1";

    # fetch hashes by running `print-hashes.sh ${bootstrapVersion}`
    bootstrapHashes = {
      i686-unknown-linux-gnu = "7ed2f462bf353060233899722393d78845068f89b15711db03aeba7f2290362f";
      x86_64-unknown-linux-gnu = "fa99eb4e823fdeb8ee25e486c7973b4803013ac68c64e8f74880da788db9739c";
      x86_64-unknown-linux-musl = "6a57ddfffa77bfa97ab325586b08fc1e96c3acb82ecc9f554cdb2ef748466ef2";
      arm-unknown-linux-gnueabihf = "ea1f3ac40a1ee0982dcf1ffafda9ec6b085f6ef518dbe86fb4d361248651f7bb";
      armv7-unknown-linux-gnueabihf = "308269db08f9a43ff11d31c41644f953376acc178aa826f3cfdb57bb6e5b2837";
      aarch64-unknown-linux-gnu = "701d55b62286bed013ceb2393ff7687d0953205605afaa15c62e2cd18024c32c";
      aarch64-unknown-linux-musl = "34f0ffb0cd3e334aeae344daae09984f951eeb842386406d4bdf11cd0b4c2b36";
      x86_64-apple-darwin = "3121c47ef68e46f1bb6040822abc1a4937cd1ab44e99af19b4b32677aba40a2f";
      aarch64-apple-darwin = "29777f1324ed63c0f7b1701b0977269980427119cb22fd097dc0a614996d9c60";
      powerpc64-unknown-linux-gnu = "f65a0c4b6122c75639b1a3a832fdabcb34cf45b4953a2858f84c7d1501738f91";
      powerpc64le-unknown-linux-gnu = "e18f33f26c7222569dac0eb1c8a216aefa8a0a3e1472094e6d11375b95cd40c2";
      riscv64gc-unknown-linux-gnu = "388da45034fbf65328feb0be364e1fddc06dd6c240e9bd1214ebc64554eb3a90";
      s390x-unknown-linux-gnu = "8a431036d5b96ba8cf05fe088601dc9861f47d62e70e65f5e106e74fcda694d8";
      loongarch64-unknown-linux-gnu = "2a5cd3ad7e0b3e12651c14cf671f7f67c302e1e2b6d93bb74cc2b967d0603ed4";
      loongarch64-unknown-linux-musl = "54d94046d952ae30c8e6cd3e0c2a68dd14605b2c7082619b60b0a354a5a72658";
      x86_64-unknown-freebsd = "c4283f5e1514e090139a64603d3f1502a014cd472184c13355646eef2ef04709";
    };

    selectRustPackage = pkgs: pkgs.rust_1_93;
  }

  (
    removeAttrs args [
      "llvmPackages_21"
      "llvm_21"
      "wrapCCWith"
      "overrideCC"
      "pkgsHostTarget"
      "fetchpatch"
    ]
  )
