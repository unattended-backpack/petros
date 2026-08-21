# OpenVM Trusted Setup Verification

OpenVM's proving artifacts split into three classes with three different trust stories. This document records what each one is, why it is or is not ceremony-dependent, and how Petros verifies it, mirroring the RISC Zero Groth16 ceremony verification (circom r1cs reproduction + snarkjs contribution-chain check) and the SP1 PLONK Aztec Ignition check that Petros already carries.

Four kinds of check appear below, from cheapest to heaviest:

- **Hash pins**: committed `.sha256` files answering *are these the bytes we pinned?* Run at every image build; say nothing about where the bytes came from.
- **Structural consistency**: offline format/math checks answering *are these artifacts internally coherent?* Cheap and repeatable.
- **Ceremony provenance**: re-deriving ceremony-dependent artifacts from the ceremony's own published transcript, answering *did these bytes actually come from the ceremony?* Heavy, one-time per version; the result is recorded in the bump commit and the hash pins carry it forward.
- **Deterministic reproduction**: regenerating derived artifacts from pinned code (and verified inputs), answering *are these really what the pinned code produces?* Heavy, one-time per version, recorded the same way.

## Artifact classes

| Artifact | Ceremony-dependent? | Vendored where |
| --- | --- | --- |
| `internal_recursive.pk` / `.vk` (aggregation keys) | No; deterministic keygen | hierophant `provers/openvm/<ver>/openvm-agg-keys.tar.gz` |
| `kzg_bn254_{10..24}.srs` (KZG params) | **Yes; Perpetual Powers of Tau** | petros `src/openvm/kzg/challenge_0085/` |
| `halo2.pk` (EVM proving key) | Derived: deterministic given the params | hierophant `provers/openvm/<ver>/openvm-halo2-pk.tar.gz` (content pin: `halo2.pk.sha256`) |
| EVM verifier contracts (Solidity + bytecode) | Derived: deterministic given the params and pinned `solc` | sacristy `contracts/src/l2/verifier/vendor/openvm/` (content pin: petros `src/openvm/<ver>/verifier.expected-hashes`) |

The threat model concentrates entirely on the KZG params: a substituted SRS whose secret τ is known to an attacker permits proof forgery for every halo2-wrapped (EVM) OpenVM proof. The aggregation keys, `halo2.pk`, and the verifier contracts are deterministic functions of pinned code (and, for the latter two, of the params), so their risk is drift/substitution, addressed by reproduction rather than ceremony auditing. STARK-only deployments (app and stark proof modes) never touch the ceremony-dependent artifacts at all.

## Hash pins

Every vendored file has a committed `.sha256` under `src/openvm/kzg/challenge_0085/` (Petros) or `provers/openvm/<ver>/` (hierophant), checked at every image build by the vendor scripts. This pins bytes but says nothing about provenance; the checks below establish that once, after which the pins carry it forward.

## Structural consistency (automated, repeatable)

```bash
sh src/scripts/verify-openvm-kzg.sh src/openvm/kzg/challenge_0085
```

Proves the fifteen `.srs` files are internally consistent slices of **one** SRS: exact PSE-halo2 `ParamsKZG` sizes and `k` headers, byte-exact monomial-G1 prefix agreement against the `k=24` file, and identical `[g2, s_g2]` tails. After this check, establishing provenance for the `k=24` file (below) covers all fifteen. Runs anywhere, offline, no toolchain beyond coreutils. The same checks run against the staged image copies (`/petros/share/openvm-kzg/`) as part of sacristy's `verify-trusted-setup` goal.

## Ceremony provenance (one-time per `OPENVM_KZG_VERSION`)

OpenVM's upstream params source is `s3://axiom-crypto/challenge_0085/`, i.e. a conversion of **Perpetual Powers of Tau contribution 0085** into PSE-halo2 format. The PPoT ceremony (BN254, 2^28) publishes its full transcript and per-contribution challenge files; `challenge_0085` is ~97 GB. Re-derivation:

1. **Fetch the transcript file** `challenge_0085` from the PPoT repository's published transcript listing (privacy-scaling-explorations/perpetualpowersoftau). Cross-check its hash against the response/challenge hash chain recorded in that repository.
2. **Convert** with the community converter the ecosystem's published params trace back to, pinned at a reviewed revision:

   ```bash
   git clone https://github.com/han0110/halo2-kzg-srs && cd halo2-kzg-srs
   cargo run --release --bin convert-from-perpetual-powers-of-tau -- \
     <path-to-challenge_0085> kzg_bn254_ 24
   ```

   This emits `kzg_bn254_{1..24}.srs` in raw PSE-halo2 format.
3. **Compare** the emitted `kzg_bn254_{10..24}.srs` byte-for-byte (`sha256sum`) against the vendored set. Byte equality closes the chain: vendored params ⇐ converter ⇐ ceremony transcript.

Record the transcript hash, converter revision, and comparison result in the bump commit that changes `OPENVM_KZG_VERSION`. Disk: ~100 GB for the transcript plus ~8 GB output; time is dominated by the download.

## Deterministic reproduction (one-time per `OPENVM_VERSION`)

The vendored `halo2.pk` is mirrored from `s3://openvm-public-artifacts-us-east-1/v<ver>/halo2.pk` (~9.4 GB raw for v2.0.1; vendored gzip-compressed as `openvm-halo2-pk.tar.gz`, with the raw key's hash committed separately as `halo2.pk.sha256`; that content pin is what this check compares against). It is a deterministic product of the pinned openvm code and the (provenance-verified) KZG params, so verification is regeneration:

1. On a machine with ~70 GB of RAM, inside a Petros container, seed `~/.openvm/params/` with the verified params (symlink from `/petros/share/openvm-kzg/`) and ensure **no** `~/.openvm/halo2.pk` exists.
2. Run `cargo openvm setup --evm`; with the pk absent it runs the halo2 keygen in-process.
3. `sha256sum ~/.openvm/halo2.pk` and compare against the vendored mirror's committed hash. A mismatch means upstream drift or a non-deterministic keygen path; do not promote the artifact until explained.

The verifier contracts have two derivation paths, used by two different goals:

- **`make openvm-verifier-pin`** (fast; minutes): emits the contracts from the CDN-pinned production `halo2.pk` via `src/verifier-pin-tool` (a faithful port of the SDK's private verifier emission, run directly against the seeded key; the SDK itself cannot do this, since its builder rejects a lone halo2 key and its setup path always re-runs keygen), verifies the seed against the committed `halo2.pk.sha256`, and writes `verifier.expected-hashes` for `src/openvm/<OPENVM_VERSION>/`. This binds the deployable contracts to the exact key hierophant proves with. The pin and the `halo2.pk` content pin are both staged in the image under `/petros/share/openvm/`, where sacristy's fast `verify-bindings` goal checks the vendored contracts against them.
- **sacristy's `make verify-trusted-setup-full`** (heavy; adds hours and ~70 GB RAM): regenerates `halo2.pk` from pinned code and the staged params with no seeding, compares it to the content pin (the reproduce-and-compare above, now repeatable), and byte-compares the verifier emitted from the fresh key against the vendored contracts. Note for `make openvm-agg-keys`: with `solc` now vendored, that script seeds placeholder verifier artifacts so `setup --evm` skips verifier generation, which would otherwise silently trigger the full keygen it exists to avoid.

## Aggregation keys (no ceremony)

`internal_recursive.pk`/`.vk` come from `make openvm-agg-keys` (which runs `src/scripts/generate-openvm-agg-keys.sh` inside the built Petros image; plain `cargo openvm setup`, offline, deterministic; the Petros image is what pins the keygen code). Verification is reproduction: the goal automatically checks every run against the committed `src/openvm/<OPENVM_VERSION>/agg-keys.expected-hashes` and fails on drift, so any machine with a built Petros can re-derive and confirm the published keys. The keys themselves ship only in hierophant's runtime images (`provers/openvm/`), never in Petros; they are an *output* of this build environment, and vendoring them back in would create a bootstrap cycle with no in-image consumer.
