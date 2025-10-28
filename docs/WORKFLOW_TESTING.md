# Testing Workflows with `act`

This guide explains how to test the release workflow locally using [`act`](https://github.com/nektos/act).

## Prerequisites

Before testing workflows locally, ensure you have the following tools installed on your machine:

**Required:**
- `act` - GitHub Actions local runner ([installation guide](https://github.com/nektos/act#installation)).
- `docker` - Container runtime.
- `doctl` - DigitalOcean CLI tool (pre-installed to avoid supply chain risks).

## Local Secrets Directory

Act is already configured using the [`.actrc` file](./.actrc). What is needed as well are any necessary secrets in a local `.act-secrets` directory.

```bash
mkdir -p .act-secrets

# Create test versions (replace with real values)
echo "test-do-token" > .act-secrets/do_token
echo "test-dh-token" > .act-secrets/dh_token
echo "test-ci-gh-pat" > .act-secrets/ci_gh_pat
echo "test-ci-gh-classic-pat" > .act-secrets/ci_gh_classic_pat
echo "test-gpg-private-key-base64" > .act-secrets/gpg_private_key
echo "test-gpg-passphrase" > .act-secrets/gpg_passphrase
echo "test-gpg-public-key-base64" > .act-secrets/gpg_public_key

cat > .act-secrets/registry.env <<'EOF'
DO_REGISTRY_NAME=your-registry
DH_USERNAME=your-username
EOF

chmod 700 .act-secrets
chmod 600 .act-secrets/*
```

## Usage

Once configured, run `ACT_PULL=false DOCKER_BUILD_ARGS="--network host" make act`.
