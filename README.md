# Petros

Upon this rock, I will build my church. Petros is a Docker build image containing the software tooling we need and is designed to be resilient against supply chain disruption or attack.

## About Attic

Attic is a [self-hostable Nix Binary Cache](https://github.com/zhaofengli/attic). We make extensive use of it to maintain a fully independent supply chain of Nix packages that we have built and cached. We maintain [Granary](https://github.com/unattended-backpack/granary), which is our simple solution for making it easy to host an attic server. An attic server is required for building Petros.

## Building

To build locally, you should simply need to run `make`; you can see more in the [`Makefile`](./Makefile). This will default to building with the maintainer-provided details from [`.env.maintainer`](./.env.maintainer), which we will periodically update as details change. The default token is [`attic_token`](./attic_token).

The underlying command for directly building is `docker build --secret id=attic_token,src=<token> --build-arg ATTIC_SERVER_URL=<server> --build-arg ATTIC_CACHE=<cache> --build-arg ATTIC_PUBLIC_KEY=<public_key> --build-arg ATTIC_CACHE_BUST=<hash> -t petros .`, where `<token>` is the path to a file containing your login token with appropriate permissions for a particular attic server cache, `<server>` is the URL to an attic server, `<cache>` is the name of the cache on the attic server, and `<public_key>` is the public key signing the specified cache on the attic server. The `ATTIC_CACHE_BUST` argument is typically set to the hashed value of the `attic_token` so as to trigger Docker rebuilds without using cached layers when the contents of the token change. When using `make`, any of these values from `.env.maintainer` may be overridden by specifying them as environment variables.

If the `ATTIC_SERVER_URL` is pointed to an attic server running on your local machine, you will also need to include the `--network host` flag to access it. You can supply this to `make` as `DOCKER_BUILD_ARGS='--network host' make`.

Configuration for building relies on the `nix.conf` file, where some build settings may be tuned. The `substituters` field is dynamically created to match the arguments supplied to the Docker build. The `trusted-public-keys` is also dynamically created in this fashion.

## Configuration

Petros follows a zero-trust model where all sensitive configuration is stored on the self-hosted runner, not in GitHub. This section documents the configuration required for automated releases via GitHub Actions.

### Runner-Local Secrets

All secrets must be stored on the self-hosted runner at `/opt/github-runner/secrets/`. These files are mounted read-only into the release workflow container and are never stored in GitHub.

#### Required Secrets

**GitHub Access Tokens** (for creating releases and pushing to GHCR):
- `ci_gh_pat` - A GitHub fine-grained personal access token with repository permissions.
- `ci_gh_classic_pat` - A GitHub classic personal access token for GHCR authentication.

**Registry Access Tokens** (for pushing container images):
- `do_token` - A DigitalOcean API token with container registry write access.
- `dh_token` - A Docker Hub access token.

**GPG Signing Keys** (for signing release artifacts):
- `gpg_private_key` - A base64-encoded GPG private key for signing digests.
- `gpg_passphrase` - The passphrase for the GPG private key.
- `gpg_public_key` - The base64-encoded GPG public key (included in release notes).

**Registry Configuration** (`registry.env` file):

This file contains non-sensitive registry identifiers and build configuration:

```bash
# The Docker image to perform release builds with.
# If not set, defaults to unattended/petros:latest from Docker Hub.
# Examples:
#   BUILD_IMAGE=registry.digitalocean.com/sigil/petros:latest
#   BUILD_IMAGE=ghcr.io/your-org/petros:latest
#   BUILD_IMAGE=unattended/petros:latest
BUILD_IMAGE=unattended/petros:latest

# The name of the DigitalOcean registry to publish the built image to.
DO_REGISTRY_NAME=your-registry-name

# The username of the Docker Hub account to publish the built image to.
DH_USERNAME=your-dockerhub-username
```

#### Optional Secrets

**Attic Cache Seeding** (optional):
- `attic_admin_token` - An attic token with write permissions for seeding the binary cache during release builds. If not present, the workflow uses the repository's read-only `attic_token` file.

The token selection priority order is:
1. Runner-local `/opt/github-runner/secrets/attic_admin_token` (if exists).
2. Repository `.attic_admin_token` (if exists).
3. Repository `attic_token` (read-only fallback).

### Public Configuration

Public configuration that anyone building Petros needs is stored in the repository at [`.env.maintainer`](./.env.maintainer):

- `IMAGE_NAME` - The name of the Docker image (default: `petros`).
- `ATTIC_SERVER_URL` - The URL to the attic binary cache server.
- `ATTIC_CACHE` - The name of the attic cache to use.
- `ATTIC_PUBLIC_KEY` - The public key for verifying attic cache signatures.
- `VENDOR_BASE_URL` - The base URL for downloading vendored binary tarballs.

This file is version-controlled and updated by maintainers as infrastructure details change.

## The Attic Token

The [`attic_token`](./attic_token) file distributed with this repository has read-only access to Unattended Backpack's public Nix binary attic cache; you may use it when building Petros from source to fetch builds of cached derivations. If you point to a different attic cache than ours, you may want to supply your own token with write permissions so that you may cache binaries as they are built. You may host your own attic cache and generate these tokens with [Granary](https://github.com/unattended-backpack/granary), our simple solution for making it easier to host an attic server.

If you opt to prepare your own attic server, you will need to bootstrap Petros with some available attic binaries. Instructions for bootstrapping are provided [here](./docs/BOOTSTRAP.md).

## Verifying Release Artifacts

All releases include GPG-signed artifacts for verification. Each release contains:

- `image-digests.txt` - A human-readable list of container image digests.
- `image-digests.txt.asc` - A GPG signature for the digest list.
- `ghcr-manifest.json` / `ghcr-manifest.json.asc` - A GitHub Container Registry OCI manifest and signature.
- `dh-manifest.json` / `dh-manifest.json.asc` - A Docker Hub OCI manifest and signature.
- `do-manifest.json` / `do-manifest.json.asc` - A DigitalOcean Container Registry OCI manifest and signature.

### Quick Verification

Download the artifacts and verify signatures:

```bash
# Import the GPG public key (base64-encoded in release notes).
echo "<GPG_PUBLIC_KEY>" | base64 -d | gpg --import

# Verify digest list.
gpg --verify image-digests.txt.asc image-digests.txt

# Verify image manifests.
gpg --verify ghcr-manifest.json.asc ghcr-manifest.json
gpg --verify dh-manifest.json.asc dh-manifest.json
gpg --verify do-manifest.json.asc do-manifest.json
```

### Manifest Verification

The manifest files contain the complete OCI image structure (layers, config, metadata). To verify that a registry hasn't tampered with an image:

```bash
# Pull the manifest from the registry.
docker manifest inspect ghcr.io/unattended-backpack/petros@sha256:... \
  --verbose > registry-manifest.json

# Compare to the signed manifest.
diff ghcr-manifest.json registry-manifest.json

# If identical, the registry image matches the signed manifest.
```

This provides cryptographic proof that the image structure (all layers and configuration) matches what was signed at release time.

### Cosign Verification (Optional)

Images are also signed with [cosign](https://github.com/sigstore/cosign) using GitHub Actions OIDC for keyless signing. This provides automated verification and build provenance.

To verify with cosign:
```bash
# Verify image signature (proves it was built by GitHub Actions workflow)
cosign verify ghcr.io/unattended-backpack/petros@sha256:... \
  --certificate-identity-regexp='^https://github.com/unattended-backpack/.+' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com
```

Cosign verification provides:
- Automated verification (no manual GPG key management).
- Build provenance (proves image was built by the GitHub Actions workflow).
- Registry-native signatures (stored alongside images).

**Note**: Cosign depends on external infrastructure (GitHub OIDC, Rekor). For maximum trust independence, rely on the GPG-signed manifests as your ultimate root of trust.

## Local Testing

This repository is configured to support testing the release workflow locally using the `act` tool. There is a corresponding goal in the Makefile, and instructions for further management of secrets [here](./docs/WORKFLOW_TESTING.md). This local testing file also shows how to configure the required secrets for building.

## Regarding Vendored Nix Packages

The Nix packages are vendored to keep us pinned to a specific version and to support overriding some default mirrors. At the time of creating this project, the GNU FTP mirrors [were being attacked](https://www.fsf.org/blogs/sysadmin/our-small-team-vs-millions-of-bots). We had to update the sources used for some dependencies to ensure that alternative mirrors were used. We encourage donating to the Free Software Foundation [here](https://my.fsf.org/donate).

We have taken the opportunity presented to vendor some of our own packages as well, such as separate versions of Rust that we need. All told, vendoring the packages like this helps bring us further security against any supply chain attacks.

# Security

If you discover any bug; flaw; issue; dæmonic incursion; or other malicious, negligent, or incompetent action that impacts the security of any of these projects please responsibly disclose them to us; instructions are available [here](./SECURITY.md).

# License

The [license](./LICENSE) for all of our original work is `LicenseRef-VPL WITH AGPL-3.0-only`. This includes every asset in this repository: code, documentation, images, branding, and more. You are licensed to use all of it so long as you maintain _maximum possible virality_ and our copyleft licenses.

Permissive open source licenses are tools for the corporate subversion of libre software; visible source licenses are an even more malignant scourge. All original works in this project are to be licensed under the most aggressive, virulently-contagious copyleft terms possible. To that end everything is licensed under the [Viral Public License](./licenses/LicenseRef-VPL) coupled with the [GNU Affero General Public License v3.0](./licenses/AGPL-3.0-only) for use in the event that some unaligned party attempts to weasel their way out of copyleft protections. In short: if you use or modify anything in this project for any reason, your project must be licensed under these same terms.

For art assets specifically, in case you want to further split hairs or attempt to weasel out of this virality, we explicitly license those under the viral and copyleft [Free Art License 1.3](./licenses/FreeArtLicense-1.3).
