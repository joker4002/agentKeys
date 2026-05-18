#!/usr/bin/env node
// heima-paseo-sudo.mjs — Node helper that wraps pallet_sudo on Heima Paseo
// for AgentKeys stage-1 bring-up tasks. PASEO ONLY — refuses to run against
// Heima mainnet (chain ID 212013) because mainnet has no sudo and any call
// would either fail or, worse, hit some leftover testnet hook.
//
// Subcommands:
//   fund       — sudo-transfer HEI from Alice to a target EVM address
//   bootstrap  — sudo-wrap a Substrate or EVM extrinsic for one-shot bootstrap
//                (e.g., set K3EpochCounter signer governance, force-set scope)
//   whoami     — print the sudo key's SS58 (under Heima prefix 31) for sanity
//
// Usage:
//   # Install deps once (npx fetches them for you on first run if absent)
//   npx --package=@polkadot/api --package=@polkadot/keyring \
//       --package=@polkadot/util-crypto -- node scripts/heima-paseo-sudo.mjs <subcommand> ...
//
//   # Fund a deployer with 100 HEI
//   node scripts/heima-paseo-sudo.mjs fund \
//        --recipient 0xYOUR_EVM_DEPLOYER \
//        --amount-hei 100
//
//   # Set K3EpochCounter signer-governance multisig
//   node scripts/heima-paseo-sudo.mjs bootstrap \
//        --target $K3_EPOCH_COUNTER_ADDRESS \
//        --calldata 0x...   # ABI-encoded set_signer_governance(multisig)
//
//   # Sanity-check the sudoer
//   node scripts/heima-paseo-sudo.mjs whoami
//
// PASEO ONLY. Refuses to run if the connected node's eth_chainId == 212013
// (Heima mainnet). Defaults to reading $AGENTKEYS_CHAIN — but ignores any
// value that isn't heima-paseo.

import { spawnSync } from 'node:child_process';

// Polkadot deps are loaded lazily so --help works without them installed.
// The bring-up script (heima-paseo-bring-up.sh) auto-fetches them via
// `npx --package=@polkadot/api ... -- node scripts/heima-paseo-sudo.mjs`.
let polkadotApi, polkadotKeyring, polkadotUtilCrypto, polkadotUtil;
async function loadPolkadotDeps() {
  if (polkadotApi) return;
  try {
    polkadotApi        = await import('@polkadot/api');
    polkadotKeyring    = await import('@polkadot/keyring');
    polkadotUtilCrypto = await import('@polkadot/util-crypto');
    polkadotUtil       = await import('@polkadot/util');
  } catch (e) {
    console.error(`[heima-paseo-sudo] missing polkadot deps. Run via:`);
    console.error(`  npx --package=@polkadot/api --package=@polkadot/keyring \\`);
    console.error(`      --package=@polkadot/util-crypto --package=@polkadot/util \\`);
    console.error(`      -y node scripts/heima-paseo-sudo.mjs <subcommand> ...`);
    console.error(`OR npm install -g @polkadot/api @polkadot/keyring @polkadot/util-crypto @polkadot/util`);
    process.exit(1);
  }
}

const MAINNET_CHAIN_ID_BIGINT = 212013n;

// ---- profile resolution -------------------------------------------------
function loadProfile() {
  const target = process.env.AGENTKEYS_CHAIN || 'heima-paseo';
  if (target !== 'heima-paseo') {
    console.error(
      `heima-paseo-sudo.mjs: AGENTKEYS_CHAIN=${target} but this script is paseo-only. ` +
      `Re-run with AGENTKEYS_CHAIN=heima-paseo OR pass --chain heima-paseo.`
    );
    process.exit(1);
  }
  const out = spawnSync('agentkeys', ['chain', 'show', 'heima-paseo'], { encoding: 'utf8' });
  if (out.status !== 0) {
    console.error(`agentkeys chain show heima-paseo failed (exit ${out.status}). Is the CLI built and on $PATH?`);
    console.error(out.stderr);
    process.exit(1);
  }
  return JSON.parse(out.stdout);
}

async function connect(profile) {
  await loadPolkadotDeps();
  const { ApiPromise, WsProvider } = polkadotApi;
  const wssUrl = profile.rpc.substrate_wss || profile.rpc.wss;
  console.error(`[heima-paseo-sudo] connecting to ${wssUrl} …`);
  const provider = new WsProvider(wssUrl);
  const api = await ApiPromise.create({ provider });
  await api.isReady;

  // Refuse to run against mainnet — defensive sanity check.
  const chainNameOut = (await api.rpc.system.chain()).toString();
  const properties = (await api.rpc.system.properties()).toJSON();
  console.error(`[heima-paseo-sudo] connected to chain="${chainNameOut}" ss58=${properties.ss58Format} token=${properties.tokenSymbol}`);

  // Heima Paseo's chain_id is encoded as 0 in the profile (auto-detect).
  // Read live via JSON-RPC `eth_chainId` if the HTTP endpoint differs.
  try {
    const ethChainIdResult = await api.rpc.eth.chainId();
    const chainIdBigint = BigInt(ethChainIdResult.toString());
    if (chainIdBigint === MAINNET_CHAIN_ID_BIGINT) {
      console.error(`[heima-paseo-sudo] REFUSING — connected to Heima MAINNET (chain_id=${chainIdBigint}). Sudo not present here, but mis-targeting is the failure mode this guard catches.`);
      process.exit(2);
    }
    console.error(`[heima-paseo-sudo] EVM chain_id=${chainIdBigint} (paseo, ok)`);
  } catch (e) {
    console.error(`[heima-paseo-sudo] couldn't read eth_chainId (${e.message}); proceeding without the EVM chain-id guard. Mainnet substrate-chain name is also "Heima" — verify your RPC URL.`);
  }

  return { api, properties };
}

function aliceKeyring(ss58Format) {
  // Well-known Substrate dev seed (//Alice). PASEO ONLY.
  const { Keyring } = polkadotKeyring;
  const keyring = new Keyring({ type: 'sr25519', ss58Format });
  return keyring.addFromUri('//Alice');
}

// ---- subcommands --------------------------------------------------------
function parseFlags(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const val = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : 'true';
      out[key] = val;
    }
  }
  return out;
}

// Heima uses HashedAddressMapping<BlakeTwo256>. Substrate account that
// corresponds to an EVM address is derived as:
//   blake2_256("evm:" || eth_address)
// We use this to fund the *Substrate-side balance* of the EVM deployer key,
// since pallet_balances knows about Substrate accounts, not EVM ones.
function evmToSubstrate(evmAddress) {
  const { hexToU8a, u8aToHex } = polkadotUtil;
  const { blake2AsU8a } = polkadotUtilCrypto;
  const stripped = evmAddress.toLowerCase().replace(/^0x/, '');
  if (stripped.length !== 40) {
    throw new Error(`invalid EVM address: expected 40 hex chars, got ${stripped.length}`);
  }
  const prefix = new TextEncoder().encode('evm:');
  const ethBytes = hexToU8a('0x' + stripped);
  const combined = new Uint8Array(prefix.length + ethBytes.length);
  combined.set(prefix, 0);
  combined.set(ethBytes, prefix.length);
  return u8aToHex(blake2AsU8a(combined, 256));
}

async function cmdFund(flags) {
  if (!flags.recipient) throw new Error('--recipient <0xEVM_ADDRESS> required');
  if (!flags['amount-hei']) throw new Error('--amount-hei <N> required');
  const profile = loadProfile();
  const { api, properties } = await connect(profile);
  const alice = aliceKeyring(properties.ss58Format);
  console.error(`[heima-paseo-sudo] Alice SS58 (prefix ${properties.ss58Format}): ${alice.address}`);

  const recipientSubstrate = evmToSubstrate(flags.recipient);
  console.error(`[heima-paseo-sudo] EVM recipient ${flags.recipient} → Substrate ${recipientSubstrate}`);

  const { BN } = polkadotUtil;
  const decimals = properties.tokenDecimals;
  const amount = new BN(flags['amount-hei']).mul(new BN(10).pow(new BN(decimals)));
  console.error(`[heima-paseo-sudo] transferring ${flags['amount-hei']} ${properties.tokenSymbol} (=${amount.toString()} units)`);

  const inner = api.tx.balances.forceTransfer(alice.address, recipientSubstrate, amount);
  const sudo = api.tx.sudo.sudo(inner);

  return new Promise((resolve, reject) => {
    sudo.signAndSend(alice, ({ status, dispatchError, events }) => {
      if (dispatchError) {
        if (dispatchError.isModule) {
          const decoded = api.registry.findMetaError(dispatchError.asModule);
          reject(new Error(`dispatchError: ${decoded.section}.${decoded.name}: ${decoded.docs.join(' ')}`));
        } else {
          reject(new Error(`dispatchError: ${dispatchError.toString()}`));
        }
        return;
      }
      if (status.isInBlock) {
        console.error(`[heima-paseo-sudo] in block ${status.asInBlock.toHex()}`);
      } else if (status.isFinalized) {
        console.error(`[heima-paseo-sudo] finalized ${status.asFinalized.toHex()}`);
        for (const { event } of events) {
          if (event.section === 'sudo' && event.method === 'Sudid') {
            const result = event.data.toJSON()[0];
            console.error(`[heima-paseo-sudo] sudo.Sudid result: ${JSON.stringify(result)}`);
          }
        }
        console.log(JSON.stringify({
          ok: true,
          recipient_evm: flags.recipient,
          recipient_substrate: recipientSubstrate,
          amount_hei: flags['amount-hei'],
          finalized_block: status.asFinalized.toHex(),
        }, null, 2));
        resolve();
      }
    }).catch(reject);
  });
}

async function cmdBootstrap(flags) {
  if (!flags.target) throw new Error('--target <0xEVM_CONTRACT_ADDRESS> required');
  if (!flags.calldata) throw new Error('--calldata <0x...> (ABI-encoded function call) required');
  const profile = loadProfile();
  const { api, properties } = await connect(profile);
  const alice = aliceKeyring(properties.ss58Format);

  // Wrap an EVM call via pallet_ethereum::transact, then sudo it. This lets
  // Alice call any Solidity function as if msg.sender were Alice's
  // EVM-mapped address.
  const evmCall = api.tx.ethereum.transact({
    EIP1559: {
      chainId: profile.chain_id || 0,   // 0 = let node infer from runtime
      nonce: 0,
      maxPriorityFeePerGas: 0,
      maxFeePerGas: 0,
      gasLimit: 5_000_000,
      action: { Call: flags.target },
      value: 0,
      input: flags.calldata,
      accessList: [],
      oddYParity: false,
      r: '0x' + '00'.repeat(32),
      s: '0x' + '00'.repeat(32),
    },
  });
  const sudo = api.tx.sudo.sudo(evmCall);

  console.error(`[heima-paseo-sudo] sudo.sudo(ethereum.transact(target=${flags.target}, calldata=${flags.calldata.slice(0, 12)}…))`);
  return new Promise((resolve, reject) => {
    sudo.signAndSend(alice, ({ status, dispatchError }) => {
      if (dispatchError) {
        reject(new Error(`dispatchError: ${dispatchError.toString()}`));
        return;
      }
      if (status.isFinalized) {
        console.log(JSON.stringify({ ok: true, finalized_block: status.asFinalized.toHex() }, null, 2));
        resolve();
      }
    }).catch(reject);
  });
}

async function cmdWhoami() {
  const profile = loadProfile();
  const { api, properties } = await connect(profile);
  const alice = aliceKeyring(properties.ss58Format);
  const account = await api.query.system.account(alice.address);
  console.log(JSON.stringify({
    sudoer_alias: 'alice',
    sudoer_ss58_on_chain: alice.address,
    sudoer_pubkey: polkadotUtil.u8aToHex(alice.publicKey),
    chain_ss58_format: properties.ss58Format,
    chain_token: properties.tokenSymbol,
    chain_decimals: properties.tokenDecimals,
    alice_balance: account.data.free.toString(),
  }, null, 2));
}

// ---- entrypoint ---------------------------------------------------------
async function main() {
  const [subcommand, ...rest] = process.argv.slice(2);
  const flags = parseFlags(rest);
  if (!subcommand || subcommand === '--help' || subcommand === '-h') {
    console.log(`heima-paseo-sudo.mjs — Alice-sudo helper for Heima Paseo dev bring-up.

Usage:
  node scripts/heima-paseo-sudo.mjs fund      --recipient 0xADDR --amount-hei 100
  node scripts/heima-paseo-sudo.mjs bootstrap --target 0xCONTRACT --calldata 0xABI
  node scripts/heima-paseo-sudo.mjs whoami

Refuses to run against Heima mainnet (chain_id=212013). Reads the active
chain profile via 'agentkeys chain show heima-paseo'.

Dependencies (@polkadot/api etc.) are loaded lazily — install via:
  npm install -g @polkadot/api @polkadot/keyring @polkadot/util-crypto @polkadot/util
OR let the bring-up script (heima-paseo-bring-up.sh) fetch them via npx.`);
    process.exit(subcommand ? 0 : 1);
  }
  await loadPolkadotDeps();
  await polkadotUtilCrypto.cryptoWaitReady();
  try {
    switch (subcommand) {
      case 'fund':       await cmdFund(flags); break;
      case 'bootstrap':  await cmdBootstrap(flags); break;
      case 'whoami':     await cmdWhoami(); break;
      default:
        console.error(`unknown subcommand: ${subcommand}`);
        process.exit(1);
    }
  } catch (e) {
    console.error(`[heima-paseo-sudo] ERROR: ${e.message}`);
    process.exit(1);
  }
  process.exit(0);
}

main();
