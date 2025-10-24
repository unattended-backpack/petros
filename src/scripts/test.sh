#!/usr/bin/env sh
# test.sh - Test that specified binaries are working correctly.
# Usage: test.sh <binary> [binary ...]
# Example: test.sh bash ls cat gcc

set -euo pipefail

# Ensure at least one binary was specified.
if [ $# -eq 0 ]; then
    echo "Usage: $0 <binary-name> [binary-name2 ...]"
    echo "Example: $0 bash ls cat gcc"
    exit 1
fi

echo "[test] Testing binaries: $*"

failed=0
for binary in "$@"; do
    if command -v "$binary" >/dev/null 2>&1; then
        # Temporarily disable exit-on-error to capture exit codes
        set +e

        # Try --version first (most common)
        version_output=$("$binary" --version 2>&1 | head -n1)
        exit_code=$?

        # Re-enable exit-on-error
        set -e

        # Accept 0 (success) or 141 (SIGPIPE from head -n1)
        if [ $exit_code -eq 0 ] || [ $exit_code -eq 141 ]; then
            echo "[test]   ✓ $binary ($version_output)"
        else
            # Temporarily disable exit-on-error again
            set +e

            # Fallback to 'version' subcommand (e.g., doctl, kubectl)
            version_output=$("$binary" version 2>&1 | head -n1)
            exit_code=$?

            # Re-enable exit-on-error
            set -e

            # Accept 0 (success) or 141 (SIGPIPE from head -n1)
            if [ $exit_code -eq 0 ] || [ $exit_code -eq 141 ]; then
                echo "[test]   ✓ $binary ($version_output)"
            else
                echo "[test]   ✗ $binary version check failed (tried --version and version)"
                failed=$((failed + 1))
            fi
        fi
    else
        echo "[test]   ✗ $binary not found in PATH"
        failed=$((failed + 1))
    fi
done

# Report final test results.
if [ $failed -gt 0 ]; then
    echo "[test] FAILED: $failed binary(ies) failed"
    exit 1
else
    echo "[test] All tests passed"
fi
