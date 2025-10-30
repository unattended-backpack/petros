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

# Sign image manifests from registries
echo ""
echo "Fetching and signing image manifests ..."

# Sign GHCR manifest
echo "Fetching GHCR manifest ..."
if docker manifest inspect \
    "ghcr.io/$GITHUB_REPOSITORY@$GHCR_DIGEST" \
    --verbose > release-artifacts/ghcr-manifest.json 2>/dev/null; then

  echo "Signing ghcr-manifest.json ..."
  if gpg --batch --yes --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" \
      --armor --detach-sign \
      --local-user "$KEY_ID" \
      release-artifacts/ghcr-manifest.json 2>/dev/null; then
    echo "✅ Signed ghcr-manifest.json"
  else
    echo "❌ Failed to sign ghcr-manifest.json"
    exit 1
  fi
else
  echo "❌ Failed to fetch GHCR manifest"
  exit 1
fi

# Sign Docker Hub manifest
echo "Fetching Docker Hub manifest ..."
if docker manifest inspect \
    "$DH_USERNAME/$IMAGE_NAME@$DH_DIGEST" \
    --verbose > release-artifacts/dh-manifest.json 2>/dev/null; then

  echo "Signing dh-manifest.json ..."
  if gpg --batch --yes --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" \
      --armor --detach-sign \
      --local-user "$KEY_ID" \
      release-artifacts/dh-manifest.json 2>/dev/null; then
    echo "✅ Signed dh-manifest.json"
  else
    echo "❌ Failed to sign dh-manifest.json"
    exit 1
  fi
else
  echo "❌ Failed to fetch Docker Hub manifest"
  exit 1
fi

# Sign DigitalOcean manifest
echo "Fetching DigitalOcean manifest ..."
if docker manifest inspect \
    "registry.digitalocean.com/$DO_REGISTRY_NAME/$IMAGE_NAME@$DO_DIGEST" \
    --verbose > release-artifacts/do-manifest.json 2>/dev/null; then

  echo "Signing do-manifest.json ..."
  if gpg --batch --yes --pinentry-mode loopback \
      --passphrase "$GPG_PASSPHRASE" \
      --armor --detach-sign \
      --local-user "$KEY_ID" \
      release-artifacts/do-manifest.json 2>/dev/null; then
    echo "✅ Signed do-manifest.json"
  else
    echo "❌ Failed to sign do-manifest.json"
    exit 1
  fi
else
  echo "❌ Failed to fetch DigitalOcean manifest"
  exit 1
fi

# Verify all manifest signatures
echo ""
echo "Verifying manifest signatures ..."
ALL_VERIFIED=true

for manifest in ghcr dh do; do
  if gpg --verify \
      "release-artifacts/${manifest}-manifest.json.asc" \
      "release-artifacts/${manifest}-manifest.json" 2>&1 | \
      grep -q "Good signature"; then
    echo "✅ ${manifest}-manifest.json signature verified"
  else
    echo "❌ ${manifest}-manifest.json signature verification failed"
    ALL_VERIFIED=false
  fi
done

if [ "$ALL_VERIFIED" = false ]; then
  echo "❌ Some manifest signatures failed verification"
  exit 1
fi

# List artifacts
echo ""
echo "Signed artifacts:"
ls -lh release-artifacts/

echo "signing_success=true" >> $GITHUB_OUTPUT
