# Vendored OpenVM verifier contract sources

Byte-exact copies from the pinned openvm release (tag `v2.0.1`,
`crates/sdk/contracts/`); the SDK embeds them via `include_str!` in a
private module, so the tool carries its own copies:

- `template/OpenVmHalo2Verifier.sol`; the wrapper template whose
  `{PUBLIC_VALUES_LENGTH}` and `{OPENVM_VERSION}` placeholders the tool
  fills from the loaded proving key.
- `src/IOpenVmHalo2Verifier.sol`; the verifier interface, emitted
  verbatim.

Do NOT edit these files; the emitted contracts must match the upstream
`cargo openvm setup --evm` output byte for byte. Refresh both copies in
lockstep with OPENVM_VERSION bumps. Drift is caught downstream twice:
sacristy `verify-bindings` compares the pin against its independently
vendored openvm-solidity-sdk contracts, and the full reproduction goal
regenerates everything from an unseeded key.
