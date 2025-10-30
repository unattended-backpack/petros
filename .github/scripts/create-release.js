/**
  Create a GitHub release with container image information and GPG-signed artifacts.

  @param {Object} params - GitHub Actions script context
  @param {Object} params.github - Pre-authenticated GitHub API client
  @param {Object} params.context - Workflow context
  @param {Object} params.core - GitHub Actions core utilities

  @returns {Promise<void>}
*/
module.exports = async ({ github, context, core }) => {
  const fs = require('fs');
  const path = require('path');

  // Get workflow inputs from environment
  const sha = process.env.GITHUB_SHA;
  const timestamp = process.env.BUILD_TIMESTAMP;
  const shaShort = process.env.BUILD_SHA_SHORT;
  const imageName = process.env.IMAGE_NAME;
  const repository = process.env.GITHUB_REPOSITORY;
  const doRegistryName = process.env.DO_REGISTRY_NAME;
  const dhUsername = process.env.DH_USERNAME;

  // Get digest outputs
  const doDigest = process.env.DO_DIGEST;
  const ghcrDigest = process.env.GHCR_DIGEST;
  const dhDigest = process.env.DH_DIGEST;

  // Check if we should proceed
  if (!doDigest || !ghcrDigest || !dhDigest) {
    console.log('Missing registry pushes, skipping release.');
    return;
  }

  // Get release notes and verification status
  const releaseNotes = process.env.RELEASE_NOTES || '';
  const gpgPublicKey = process.env.GPG_PUBLIC_KEY || '';
  const containerSuccess = process.env.IMAGE_MATCH === 'true';
  const imageId = process.env.IMAGE_ID;

  // Prepare the release body
  const body = `## Release Notes

${releaseNotes}

## Container Images

Images have been pushed to the following container registries; some may be private.
${ghcrDigest ? `- GHCR: \`ghcr.io/${repository}:${sha}\`` : '- GHCR: ❌'}
${dhDigest ? `- DHCR: \`${dhUsername}/${imageName}:${sha}\`` : '- DHCR: ❌'}
${doDigest ? `- DOCR: \`registry.digitalocean.com/${doRegistryName}/${imageName}:${sha}\`` : '- DOCR: ❌'}

\`\`\`bash
docker pull ghcr.io/${repository}@${ghcrDigest}
docker pull ${dhUsername}/${imageName}@${dhDigest}
docker pull registry.digitalocean.com/${doRegistryName}/${imageName}@${doDigest}
\`\`\`

After pulling from a registry, verify the image ID matches \`${imageId}\` by running \`docker inspect ${imageName} --format='{{.Id}}'\`.

## GPG Signature Verification

All release artifacts are signed with GPG, including:
- \`image-digests.txt\` - A human-readable digest list.
- \`ghcr-manifest.json\` - The complete GHCR image manifest.
- \`dh-manifest.json\` - The complete Docker Hub image manifest.
- \`do-manifest.json\` - The complete DigitalOcean image manifest.

Download the artifacts and their \`.asc\` signature files from the release assets below. To verify authenticity, copy this public key \`${gpgPublicKey}\` into a \`public.asc\` file and verify the signatures:

\`\`\`bash
# Import GPG public key.
cat public.asc | base64 -d | gpg --import

# Verify digest list.
gpg --verify image-digests.txt.asc image-digests.txt

# Verify image manifests.
gpg --verify ghcr-manifest.json.asc ghcr-manifest.json
gpg --verify dh-manifest.json.asc dh-manifest.json
gpg --verify do-manifest.json.asc do-manifest.json
\`\`\`

Valid signatures confirm the artifacts were signed by the maintainer. The manifest signatures provide cryptographic proof of the complete image structure.

## Cosign Verification (Optional)

Images are also signed with [cosign](https://github.com/sigstore/cosign) using GitHub Actions OIDC for automated verification and build provenance:

\`\`\`bash
# Verify GHCR image
cosign verify ghcr.io/${repository}@${ghcrDigest} \\
  --certificate-identity-regexp='^https://github.com/${repository.split('/')[0]}/.+' \\
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com

# Verify Docker Hub image
cosign verify ${dhUsername}/${imageName}@${dhDigest} \\
  --certificate-identity-regexp='^https://github.com/${repository.split('/')[0]}/.+' \\
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com

# Verify DigitalOcean image
cosign verify registry.digitalocean.com/${doRegistryName}/${imageName}@${doDigest} \\
  --certificate-identity-regexp='^https://github.com/${repository.split('/')[0]}/.+' \\
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com
\`\`\`

Cosign provides automated verification without manual key management. Signatures prove the images were built by this repository's GitHub Actions workflow and are stored in the [Rekor transparency log](https://search.sigstore.dev/).

**Note**: Cosign depends on external infrastructure (GitHub OIDC, Rekor). For maximum trust independence, rely on the GPG-signed manifests as your ultimate root of trust.
`;

  // Create the release
  const release = await github.rest.repos.createRelease({
    owner: context.repo.owner,
    repo: context.repo.repo,
    tag_name: `${timestamp}-${shaShort}`,
    name: `${imageName} ${shaShort}`,
    body: body,
    draft: false,
    prerelease: !containerSuccess,
    target_commitish: sha
  });
  console.log(`Created release: ${release.data.html_url}`);

  // Upload signed artifacts
  const artifactsDir = 'release-artifacts';
  const artifacts = fs.readdirSync(artifactsDir);
  for (const artifact of artifacts) {
    const artifactPath = path.join(artifactsDir, artifact);
    const stats = fs.statSync(artifactPath);

    if (stats.isFile()) {
      console.log(`Uploading artifact: ${artifact}`);
      await github.rest.repos.uploadReleaseAsset({
        owner: context.repo.owner,
        repo: context.repo.repo,
        release_id: release.data.id,
        name: artifact,
        data: fs.readFileSync(artifactPath)
      });
    }
  }

  core.setOutput('RELEASE_SUCCESS', true);
  core.setOutput('RELEASE_ID', release.data.id);
};
