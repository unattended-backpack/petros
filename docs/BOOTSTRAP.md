# Bootstrapping Attic for Private Cache

This document explains how to bootstrap the vendored attic binaries to solve the chicken-and-egg problem of needing attic to authenticate against a private cache.

## The Problem

To build the Petros image with a private attic cache, you need:
- The attic client to authenticate and fetch packages from the private cache
- But the attic client itself needs to be fetched from somewhere

## The Solution

We vendor attic binaries and their full dependency closure as a tarball that gets extracted early in the Docker build, before trying to use the private cache.

## One-Time Setup (When Attic Needs Updating)

1. **Temporarily make your attic cache public** (or use substituters that have attic)

2. **Run the bootstrap script:**
   ```bash
   ./src/scripts/bootstrap-attic.sh
   ```

   This will:
   - Build `attic-client` and `attic-server` from nixpkgs
   - Compute their full dependency closure
   - Create a tarball at `src/attic/attic-store.tar.gz`
   - Generate checksums and store paths
   - Create these files:
     - `src/attic/attic-store.tar.gz` - The vendored store paths
     - `src/attic/attic-store.tar.gz.sha256` - Checksum for verification
     - `src/attic/attic-client.outpath` - Path to attic client binary
     - `src/attic/attic-server.outpath` - Path to atticadm binary

3. **Make your cache private again**

4. **Commit the vendored files** to your repository

## How It Works

During the Docker build (Dockerfile:87-103):

1. The vendored attic tarball is copied into the builder image
2. The checksum is verified
3. The tarball is extracted to `/nix/store/`
4. Symlinks are created to make `attic` and `atticadm` available on the PATH
5. The rest of the build can now use attic to authenticate against your private cache

## File Locations

- Bootstrap script: `src/scripts/bootstrap-attic.sh`
- Vendored tarball: `src/attic/attic-store.tar.gz`
- Checksum: `src/attic/attic-store.tar.gz.sha256`
- Output paths: `src/attic/attic-{client,server}.outpath`

## When to Re-bootstrap

You only need to run the bootstrap script again when:
- You want to update to a newer version of attic
- Your nixpkgs version changes significantly
- The vendored attic binaries become incompatible with your system

## Verification

After bootstrapping, you can verify the files were created:
```bash
ls -lh src/attic/attic-store.tar.gz
sha256sum -c src/attic/attic-store.tar.gz.sha256
```

The tarball will typically be 50-100MB (compressed) depending on the attic dependencies.
