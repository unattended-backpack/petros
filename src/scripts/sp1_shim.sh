#!/bin/sh
# sp1_shim.sh - Force cargo-prove to use the Succinct toolchain.
# Sets RUSTUP_TOOLCHAIN so nested rustc/cargo calls use succinct.

export RUSTUP_TOOLCHAIN=succinct
exec /petros/bin/cargo-prove "$@"
