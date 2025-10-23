# Petros

Petros is a Docker build image containing the software tooling we need and is designed to be resilient against supply chain disruption or attack.

## About Attic

Attic is a [self-hostable Nix Binary Cache](https://github.com/zhaofengli/attic). We make extensive use of it to maintain a fully independent supply chain of Nix packages that we have built and cached. We maintain [Granary](https://github.com/unattended-backpack/granary), which is our simple solution for making it easy to host an attic server. An attic server is required for building Petros.

## Building

To build locally, you should simply need to run `make`; you can see more in the [`Makefile`](./Makefile). This will default to building with the maintainer-provided details from [`.env.maintainer`](./.env.maintainer), which we will periodically update as details change. The default token is [`attic_token`](./attic_token).

The underlying command for directly building is `docker build --secret id=attic_token,src=<token> --build-arg ATTIC_SERVER_URL=<server> --build-arg ATTIC_CACHE=<cache> --build-arg ATTIC_PUBLIC_KEY=<public_key> --build-arg ATTIC_CACHE_BUST=<hash> -t petros .`, where `<token>` is the path to a file containing your login token with appropriate permissions for a particular attic server cache, `<server>` is the URL to an attic server, `<cache>` is the name of the cache on the attic server, and `<public_key>` is the public key signing the specified cache on the attic server. The `ATTIC_CACHE_BUST` argument is typically set to the hashed value of the `attic_token` so as to trigger Docker rebuilds without using cached layers when the contents of the token change. When using `make`, any of these values from `.env.maintainer` may be overridden by specifying them as environment variables.

If the `ATTIC_SERVER_URL` is pointed to an attic server running on your local machine, you will also need to include the `--network host` flag to access it. You can supply this to `make` as `DOCKER_BUILD_ARGS='--network host' make`.

Configuration for building relies on the `nix.conf` file, where some build settings may be tuned. The `substituters` field is dynamically created to match the arguments supplied to the Docker build. The `trusted-public-keys` is also dynamically created in this fashion.

## The Attic Token

The [`attic_token`](./attic_token) file distributed with this repository has read-only access to Unattended Backpack's public Nix binary attic cache; you may use it when building Petros from source to fetch builds of cached derivations. If you point to a different attic cache than ours, you may want to supply your own token with write permissions so that you may cache binaries as they are built. You may host your own attic cache and generate these tokens with [Granary](https://github.com/unattended-backpack/granary), our simple solution for making it easier to host an attic server.

If you opt to prepare your own attic server, you will need to bootstrap Petros with some available attic binaries. Instructions for bootstrapping are provided [here](./BOOTSTRAP.md).

## Regarding Vendored Nix Packages

The Nix packages are vendored to keep us pinned to a specific version and to support overriding some default mirrors. At the time of creating this project, the GNU FTP mirrors [were being attacked](https://www.fsf.org/blogs/sysadmin/our-small-team-vs-millions-of-bots). We had to update the sources used for some dependencies to ensure that alternative mirrors were used. We encourage donating to the Free Software Foundation [here](https://my.fsf.org/donate).

We have taken the opportunity presented to vendor some of our own packages as well, such as separate versions of Rust that we need. All told, vendoring the packages like this helps bring us further security against any supply chain attacks.

# Security

If you discover any bug; flaw; issue; dæmonic incursion; or other malicious, negligent, or incompetent action that impacts the security of any of these projects please responsibly disclose them to us; instructions are available [here](./SECURITY.md).

# License

The [license](./LICENSE) for all of our original work is `LicenseRef-VPL WITH AGPL-3.0-only`. This includes every asset in this repository: code, documentation, images, branding, and more. You are licensed to use all of it so long as you maintain _maximum possible virality_ and our copyleft licenses.

Permissive open source licenses are tools for the corporate subversion of libre software; visible source licenses are an even more malignant scourge. All original works in this project are to be licensed under the most aggressive, virulently-contagious copyleft terms possible. To that end everything is licensed under the [Viral Public License](./licenses/LicenseRef-VPL) coupled with the [GNU Affero General Public License v3.0](./licenses/AGPL-3.0-only) for use in the event that some unaligned party attempts to weasel their way out of copyleft protections. In short: if you use or modify anything in this project for any reason, your project must be licensed under these same terms.

For art assets specifically, in case you want to further split hairs or attempt to weasel out of this virality, we explicitly license those under the viral and copyleft [Free Art License 1.3](./licenses/FreeArtLicense-1.3).
