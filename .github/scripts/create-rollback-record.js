/**
  Create a GitHub issue documenting a failed release and rollback status.

  This script creates an issue when the release workflow fails, documenting:
  - Build success/failure status
  - Which registries were successfully pushed to
  - Which rollbacks succeeded or require manual intervention

  @param {Object} params - GitHub Actions script context
  @param {Object} params.github - Pre-authenticated GitHub API client
  @param {Object} params.context - Workflow context
  @param {Object} params.core - GitHub Actions core utilities

  @returns {Promise<void>}
*/
module.exports = async ({ github, context, core }) => {
  // Get workflow data from environment
  const shaShort = process.env.BUILD_SHA_SHORT;
  const timestamp = process.env.BUILD_TIMESTAMP;
  const buildSuccess = process.env.BUILD_SUCCESS === 'true';
  const releaseSuccess = process.env.RELEASE_SUCCESS === 'true';

  const doDigest = process.env.DO_DIGEST;
  const ghcrDigest = process.env.GHCR_DIGEST;
  const dhDigest = process.env.DH_DIGEST;

  const doRollback = process.env.DO_ROLLBACK_SUCCESS === 'true';
  const ghcrRollback = process.env.GHCR_ROLLBACK_SUCCESS === 'true';
  const dhRollback = process.env.DH_ROLLBACK_SUCCESS === 'true';

  const doRollbackText =
    `- DOCR Rollback: ${doRollback ? '✅' : '❌ manual intervention required.'}`;
  const ghcrRollbackText =
    `- GHCR Rollback: ${ghcrRollback ? '✅' : '❌ manual intervention required.'}`;
  const dhRollbackText =
    `- DHCR Rollback: ${dhRollback ? '✅' : '❌ manual intervention required.'}`;

  const workflowUrl = `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions`;
  const actor = process.env.GITHUB_ACTOR;

  await github.rest.issues.create({
    owner: context.repo.owner,
    repo: context.repo.repo,
    title: `⚠️ Release failed for ${shaShort}`,
    body: `# Status

Attention @${actor}, an automated release failed. This issue is generated to track the status of build success, partial releases, registry pushes and rollbacks. For full details please refer to [workflow logs](${workflowUrl}).

The automated release process attempts to build the project, push it to various container registries, ensure consistency between the container registries, and release the project.
1. If the build fails, nothing else happens.
2. If successful and consistent pushes to all container registries cannot be verified, a warning-laden partial release of the project is produced. The automated release process will attempt to restore container registry consistency by rolling back the mismatched state.
3. In the event that a registry push succeeded but its corresponding rollback failed, you will need to manually intervene to ensure consistent images between container registries.

### Build Status
- ${buildSuccess ? '✅ The build succeeded.' : '❌ The build failed.'}
- ${releaseSuccess ? '⚠️ A partial release was made.' : '✅ No release was made.'}

### Registry Pushes
- DOCR: ${doDigest ? `✅ \`${doDigest}\`` : '❌' }
- GHCR: ${ghcrDigest ? `✅ \`${ghcrDigest}\`` : '❌' }
- DHCR: ${dhDigest ? `✅ \`${dhDigest}\`` : '❌' }

### Registry Rollbacks
${doDigest ? doRollbackText : '' }
${ghcrDigest ? ghcrRollbackText : '' }
${dhDigest ? dhRollbackText : '' }
`,
    labels: ['release-failure', 'needs-investigation']
  });

  console.log('Created rollback tracking issue');
};
