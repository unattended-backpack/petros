//! Emit the OpenVM EVM verifier contracts from a pre-generated halo2
//! proving key.
//!
//! `cargo openvm setup --evm` derives the verifier from the SDK's
//! in-memory halo2 proving key, which forces the full halo2 keygen
//! even when a pinned `halo2.pk` is seeded on disk (the seed only
//! skips writing a new key). The SDK builder cannot help either: it
//! rejects a lone injected halo2 key, requiring `halo2_pk -> root_pk
//! -> agg_pk -> app_pk` to all be seeded together. So this tool
//! replicates the SDK's private `solidity.rs` emission path directly
//! against the loaded key; the codegen inputs (wrapper verifying key,
//! KZG params, vendored template sources, solc invocation) are
//! identical, so the output is byte-for-byte what upstream setup
//! emits.
//!
//! Usage: verifier-pin-tool <halo2.pk> <out-dir> <version-name>
//!
//! KZG params are read from the default `~/.openvm/params/`; the
//! caller seeds them first. The version name lands in the generated
//! source paths (and therefore the bytecode's embedded metadata hash);
//! pass "v2.0-base" to match the layout the upstream contracts were
//! generated with, so byte comparison is meaningful.

use std::{
    fs::{create_dir_all, write},
    io::Write as _,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use eyre::{ensure, eyre, WrapErr};
use openvm_sdk::{
    fs::{
        read_halo2_pk_from_file, write_evm_halo2_verifier_to_folder,
        EVM_HALO2_VERIFIER_BASE_NAME, EVM_HALO2_VERIFIER_INTERFACE_NAME,
        EVM_HALO2_VERIFIER_PARENT_NAME,
    },
    halo2_params::CacheHalo2ParamsReader,
    types::{EvmHalo2Verifier, EvmVerifierByteCode, NUM_BN254_ACCUMULATOR},
    OPENVM_VERSION,
};
use serde_json::{json, Value};

// Vendored byte-exact from the pinned openvm release; see
// contracts/README.md for provenance and refresh rules.
const EVM_HALO2_VERIFIER_TEMPLATE: &str =
    include_str!("../contracts/template/OpenVmHalo2Verifier.sol");
const EVM_HALO2_VERIFIER_INTERFACE: &str =
    include_str!("../contracts/src/IOpenVmHalo2Verifier.sol");

fn main() -> eyre::Result<()> {
    let mut args = std::env::args().skip(1);
    let (Some(pk_path), Some(out_dir), Some(version)) =
        (args.next(), args.next(), args.next())
    else {
        eyre::bail!("usage: verifier-pin-tool <halo2.pk> <out-dir> <version-name>");
    };

    eprintln!("[verifier-pin-tool] loading halo2 proving key from {pk_path} ...");
    let pk = read_halo2_pk_from_file(PathBuf::from(&pk_path))
        .map_err(|e| eyre!("read halo2 pk {pk_path}: {e}"))?;

    eprintln!("[verifier-pin-tool] generating verifier (codegen + solc) ...");
    let verifier = generate_verifier(&pk, &version)?;

    let out = PathBuf::from(&out_dir);
    write_evm_halo2_verifier_to_folder(verifier, &out, Some(&version))?;
    eprintln!("[verifier-pin-tool] wrote verifier artifacts to {out_dir}");
    Ok(())
}

/// Faithful port of the SDK's private
/// `solidity::generate_halo2_verifier_solidity_with_version_name`,
/// taking the proving key directly instead of a constructed `Sdk`.
/// Any behavioral divergence from upstream here breaks the pin's
/// byte-for-byte claim; keep in lockstep across OPENVM_VERSION bumps.
fn generate_verifier(
    pk: &openvm_sdk::keygen::Halo2ProvingKey,
    version_name: &str,
) -> eyre::Result<EvmHalo2Verifier> {
    let wrapper_k = pk.wrapper.pinning.metadata.config_params.k;
    let params_reader = CacheHalo2ParamsReader::new_with_default_params_dir();
    let params = params_reader.read_params(wrapper_k);

    // The base Halo2Verifier Solidity code from snark-verifier, via
    // the wrapper circuit (which is what produces the final EVM
    // proof).
    let fallback_verifier = pk.wrapper.generate_fallback_evm_verifier(&params);
    let halo2_verifier_code = fallback_verifier.sol_code;

    // Public values length from the wrapper circuit's instances,
    // whose layout is [0..12] KZG accumulator, [12] app_exe_commit,
    // [13] app_vm_commit, [14..] user public values.
    let num_pvs = pk
        .wrapper
        .pinning
        .metadata
        .num_pvs
        .first()
        .ok_or_else(|| eyre!("expected at least one instance column"))?;
    let pvs_length = num_pvs
        .checked_sub(NUM_BN254_ACCUMULATOR + 2)
        .ok_or_else(|| eyre!("unexpected number of wrapper circuit public values"))?;
    ensure!(
        pvs_length <= 8192,
        "OpenVM Halo2 verifier contract does not support more than 8192 public values"
    );

    let openvm_verifier_code = EVM_HALO2_VERIFIER_TEMPLATE
        .replace("{PUBLIC_VALUES_LENGTH}", &pvs_length.to_string())
        .replace("{OPENVM_VERSION}", OPENVM_VERSION);

    // Source paths mirror upstream exactly: they are compiled into
    // solc's metadata and thus into the bytecode's trailing metadata
    // hash.
    let temp_dir = tempfile::tempdir().wrap_err("failed to create temp dir")?;
    let temp_path = temp_dir.path();
    let root_path = Path::new("src").join(version_name);
    let interfaces_path = root_path.join("interfaces");
    create_dir_all(temp_path.join(&interfaces_path))?;

    let interface_file_path = interfaces_path.join(EVM_HALO2_VERIFIER_INTERFACE_NAME);
    let parent_file_path = root_path.join(EVM_HALO2_VERIFIER_PARENT_NAME);
    let base_file_path = root_path.join(EVM_HALO2_VERIFIER_BASE_NAME);

    write(
        temp_path.join(&interface_file_path),
        EVM_HALO2_VERIFIER_INTERFACE,
    )?;
    write(temp_path.join(&parent_file_path), &halo2_verifier_code)?;
    write(temp_path.join(&base_file_path), &openvm_verifier_code)?;

    let solc_input = json!({
        "language": "Solidity",
        "sources": {
            interface_file_path.to_str().unwrap(): {
                "content": EVM_HALO2_VERIFIER_INTERFACE
            },
            parent_file_path.to_str().unwrap(): {
                "content": halo2_verifier_code
            },
            base_file_path.to_str().unwrap(): {
                "content": openvm_verifier_code
            }
        },
        "settings": {
            "remappings": ["forge-std/=lib/forge-std/src/"],
            "optimizer": {
                "enabled": true,
                "runs": 100000,
                "details": {
                    "constantOptimizer": false,
                    "yul": false
                }
            },
            "evmVersion": "paris",
            "viaIR": false,
            "outputSelection": {
                "*": {
                    "*": ["metadata", "evm.bytecode.object"]
                }
            }
        }
    });

    let mut child = Command::new("solc")
        .current_dir(temp_path)
        .arg("--standard-json")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .wrap_err("failed to spawn solc")?;
    child
        .stdin
        .as_mut()
        .ok_or_else(|| eyre!("failed to open solc stdin"))?
        .write_all(solc_input.to_string().as_bytes())?;
    let output = child.wait_with_output().wrap_err("failed to read solc output")?;
    ensure!(
        output.status.success(),
        "solc exited with status {}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );

    let parsed: Value = serde_json::from_slice(&output.stdout)?;
    let bytecode = parsed
        .get("contracts")
        .and_then(|v| v.get(base_file_path.to_str().unwrap()))
        .and_then(|v| v.get("OpenVmHalo2Verifier"))
        .and_then(|v| v.get("evm"))
        .and_then(|v| v.get("bytecode"))
        .and_then(|v| v.get("object"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            eyre!(
                "no OpenVmHalo2Verifier bytecode in solc output: {}",
                String::from_utf8_lossy(&output.stdout)
            )
        })?;
    let bytecode = hex::decode(bytecode).wrap_err("invalid hex in solc bytecode")?;

    Ok(EvmHalo2Verifier {
        halo2_verifier_code,
        openvm_verifier_code,
        openvm_verifier_interface: EVM_HALO2_VERIFIER_INTERFACE.to_string(),
        artifact: EvmVerifierByteCode {
            sol_compiler_version: "0.8.19".to_string(),
            sol_compiler_options: solc_input
                .get("settings")
                .expect("settings key exists")
                .to_string(),
            bytecode,
        },
    })
}
