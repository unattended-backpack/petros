#!/bin/sh
# Sign release artifacts with GPG.
#
# This script imports a GPG private key and signs the image digest manifest
# to provide cryptographic verification of container image digests.
#
# Environment variables required:
#   - GPG_PRIVATE_KEY: Base64-encoded GPG private key
#   - GPG_PASSPHRASE: Passphrase for the GPG private key
#   - IMAGE_NAME: Name of the image being released
#   - BUILD_TIMESTAMP: Build timestamp for release identification
#   - BUILD_SHA_SHORT: Short git commit SHA
#   - GITHUB_SHA: Full git commit SHA
#   - GITHUB_REPOSITORY: Repository name (owner/repo)
#   - DO_DIGEST: DigitalOcean registry digest
#   - GHCR_DIGEST: GitHub Container Registry digest
#   - DH_DIGEST: Docker Hub digest
#   - DO_REGISTRY_NAME: DigitalOcean registry name
#   - DH_USERNAME: Docker Hub username

set -e

echo "Setting up GPG signing ..."

# Verify required secrets are present
if [ -z "$GPG_PRIVATE_KEY" ]; then
  echo "❌ GPG_PRIVATE_KEY is not set. GPG signing is mandatory."
  exit 1
fi

if [ -z "$GPG_PASSPHRASE" ]; then
  echo "❌ GPG_PASSPHRASE is not set. GPG signing is mandatory."
  exit 1
fi

# Import GPG private key (assuming base64 encoded)
echo "$GPG_PRIVATE_KEY" | base64 -d | \
  gpg --batch --quiet --import 2>/dev/null

# Get the key ID
KEY_ID=$(gpg --list-secret-keys --keyid-format LONG | \
  grep sec | awk '{print $2}' | cut -d'/' -f2 | head -1)
echo "Using GPG key ID: ${KEY_ID: -16}"

# Create artifacts directory
mkdir -p release-artifacts

# Create digest manifest file
cat > release-artifacts/image-digests.txt <<EOF
$IMAGE_NAME Container Image Digests
Release: $BUILD_TIMESTAMP-$BUILD_SHA_SHORT
Git SHA: $GITHUB_SHA
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

Verified Digest (identical across all registries):
$DO_DIGEST

Registry URLs:
- ghcr.io/$GITHUB_REPOSITORY@$GHCR_DIGEST
- $DH_USERNAME/$IMAGE_NAME@$DH_DIGEST
- registry.digitalocean.com/$DO_REGISTRY_NAME/$IMAGE_NAME@$DO_DIGEST
EOF

# Sign the digest manifest
echo "Signing image-digests.txt ..."
if gpg --batch --yes --pinentry-mode loopback \
    --passphrase "$GPG_PASSPHRASE" \
    --armor --detach-sign \
    --local-user "$KEY_ID" \
    release-artifacts/image-digests.txt 2>/dev/null; then

  if [ -f release-artifacts/image-digests.txt.asc ]; then
    echo "✅ Created signature: image-digests.txt.asc"
  else
    echo "❌ Failed to create signature file"
    exit 1
  fi
else
  echo "❌ GPG signing failed for image-digests.txt"
  exit 1
fi

# Verify the signature
if gpg --verify release-artifacts/image-digests.txt.asc \
    release-artifacts/image-digests.txt 2>&1 | \
    grep -q "Good signature"; then
  echo "✅ Signature verified successfully"
else
  echo "❌ Signature verification failed"
  exit 1
fi

# List artifacts
echo ""
echo "Signed artifacts:"
ls -lh release-artifacts/

echo "signing_success=true" >> $GITHUB_OUTPUT
