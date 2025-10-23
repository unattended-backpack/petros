#!/bin/sh
# wrapped_rustc.sh - Wrapper for rustc with +toolchain support.
# Priority: 1) +toolchain arg, 2) RUSTUP_TOOLCHAIN env, 3) direct.

# Parse +toolchain syntax from arguments.
toolchain=""
for arg in "$@"; do
  case "$arg" in
    +*) toolchain="${arg#+}"; shift; break ;;
  esac
done

# Fall back to RUSTUP_TOOLCHAIN environment variable.
if [ -z "$toolchain" ] && [ -n "$RUSTUP_TOOLCHAIN" ]; then
  toolchain="$RUSTUP_TOOLCHAIN"
fi

# Execute rustc with or without toolchain specification.
if [ -n "$toolchain" ]; then
  exec /petros/bin/rustup run "$toolchain" rustc "$@"
else
  exec /petros/bin/rustc "$@"
fi
