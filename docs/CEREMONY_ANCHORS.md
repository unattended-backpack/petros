# Ceremony Anchors

Sigil's proving stack rests on four trusted-setup ceremonies. This
document records what Petros vendors for each, where every byte came
from, and what the downstream verification proves. The governing
principle is the usual one: Petros stages facts, checks derive claims.

The design decision behind this vendor set: we do NOT vendor raw
ceremony transcripts (the multi-terabyte response chains). Chain
verification needs only the per-contribution records (update proofs of
knowledge plus resulting first-power states) and state-equality anchors
against artifacts we already stage. A fabricated record chain cannot
pass the anchors: reproducing our anchored states would require the
ceremony's discrete logs. Raw transcripts add identity-hash
recomputation, re-materialization of intermediate states, verifier
diversity, and byte-exact re-derivation of conversions; none of that is
load-bearing for soundness, and all of it remains possible later via
the mirrors inventoried in `ppot/archive-metadata.tar.gz`.

## The four ceremonies

1. **Aztec Ignition** (BN254; SP1 PLONK's universal SRS).
2. **Perpetual Powers of Tau** (BN254 phase 1; ancestor of BOTH the
   RISC Zero Hermez ptau, its state after contribution 54 plus beacon,
   and the OpenVM SRS, its state after contribution 84).
3. **RISC Zero Groth16 phase 2** (circuit-specific; 238 contributions,
   chain embedded in `stark_verify_final.zkey`).
4. **Ethereum KZG Summoning Ceremony** (BLS12-381; source of the
   `[tau]_2` constant in Sigil's L2 point-evaluation precompile and the
   L1 blob-binding path).

## Vendored artifacts

### `ppot/<PPOT_VERSION>/` (staged at `/petros/share/ppot/`)

- `pot28_0086_nopoints.ptau`; the full 67-record canonical contribution
  chain (snarkjs format, powers stripped): contributions 1..58, then
  78..86 chaining from 58 per the ceremony's documented fork. Source:
  the ceremony repo's `0086_nebra_response/` directory (the repo
  commits the cumulative record file for recent contributions).
- `ppot_0080_contributions.bin`; records 1..61 extracted independently
  from PSE's prepared `pot28_0080/ppot_0080.ptau` (section 7, via HTTP
  Range). Byte-identical to the corresponding prefix above; two
  unrelated sources agreeing on the chain.
- `response_0084_pubkey.bin`, `response_0084_prev_challenge_hash.bin`;
  the 768-byte update-pubkey tail and 64-byte predecessor-hash head of
  the raw `response_0084_jpw` (Jonathan P Wang's contribution, mirrored
  hot in Axiom's public `axiom-crypto` S3 bucket). Cross-binds record
  84 to primary ceremony bytes.
- `challenge_0085_head.bin`; the first 256 bytes of the raw
  `challenge_0085` (same Axiom mirror): its `tauG1[1]` equals both
  record 84's resulting state and the staged OpenVM SRS `g1[1]`.
- `perpetualpowersoftau-repo.bundle`; git bundle of the full ceremony
  repo: per-contribution attestations, hashes, identity links, the
  fork note. The identity layer, preserved against upstream rot.
- `archive-metadata.tar.gz`; the 20 published torrent files with
  computed infohashes, S3 storage-class inventories (probed
  2026-08-18), the witness-history file listing, the Axiom bucket
  listing, and the snarkjs README snapshot documenting Hermez
  provenance. Availability evidence and re-acquisition pointers, not
  verification inputs.

Availability context recorded here because it motivated this vendor
set: the ceremony's original hosting is dead; responses 0001..0049
are on no reachable public host (zero IPFS DHT providers); 0050..0084
sit in S3 Glacier/Deep Archive behind a request process; the
witness-history torrent swarm has zero seeders. What we vendor is
what verification actually needs, held on our own CDN.

### `ethereum-kzg/<ETH_KZG_VERSION>/` (staged at `/petros/share/ethereum-kzg/`)

- `transcript.json`; the complete sequencer transcript: 141,417
  contributions with BLS proofs of knowledge, running products, and
  ECDSA participant signatures. Fetched from the `ethereum/kzg-ceremony`
  git-LFS archive (the EF sequencer no longer resolves in DNS).
- `trusted_setup_4096.json`; the derived setup. Verified:
  its `g1_monomial`/`g2_monomial` byte-equal the transcript's 4096
  sub-ceremony powers, and `g2_monomial[1]` equals the
  `TRUSTED_SETUP_TAU_G2_BYTES` constant in Sigil consensus
  (`evm/src/precompile/bls12_381/constants.rs`).

### Additions to `risc0/groth16/<R0_GROTH16_VERSION>/`

- `attestation-gists.tar.gz`; archive of the 198 contributor
  attestation gists still live on GitHub as of 2026-08-18 (39 of 237
  already deleted; gists are user-deletable, so this preserves decaying
  evidence), with per-gist metadata (id, creation and edit timestamps;
  31 were edited after creation) and the scrape-time verification
  result. 196 attestations match contribution hashes recomputed from
  the vendored zkey. Two do not (`geekypeter` slot 29,
  `tremblaythibaultl` slot 70): unedited gists, identities matching the
  zkey's embedded names, but hashes absent from the final chain;
  consistent with p0tion discarding and redoing those contributions
  without refreshing the gist. Documented, unexplained upstream.
- `risc0-trusted-setup-ceremony.md`; snapshot of RISC Zero's
  verification doc, including their published r1cs sha256
  (`84d3c34b...`) that cross-checks our circom reproduction.

### Additions to `sp1/ignition/`

- `manifest.json`, `participants.txt`; the ceremony manifest and the
  181 address-keyed participant folders.
- `signatures.tar.gz`; all 3,520 per-transcript ECDSA signature files
  from the live `aztec-ignition` bucket. Ties the pinned points
  bundle's contribution chain to public Ethereum identities.
