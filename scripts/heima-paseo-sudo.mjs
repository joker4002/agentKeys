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
  // properties.tokenDecimals / tokenSymbol come from system_properties as
  // ARRAYS (e.g. [18], ["HEI"]) — one entry per token if the chain has
  // multiple. Heima only has HEI, so [0] is the right slot. Passing the
  // raw array to `new BN(...)` triggers bn.js's "Assertion failed" inside
  // _initNumber because BN can't construct from a non-scalar. Extract the
  // scalar first.
  // Even after .toJSON() on system_properties, the tokenDecimals slot can
  // come back as either: (a) a plain JS array [18], (b) a polkadot-wrapped
  // Vec<u32> that prints as "[18]" but isn't Array.isArray, or (c) a bare
  // scalar 18. BN.js's `_initArray` fires when it receives ANY array-like
  // it can't coerce, hence the bare "Assertion failed". Force to Number
  // via JSON.parse(JSON.stringify(...))[0] which normalizes the codec.
  const decimalsRaw = JSON.parse(JSON.stringify(properties.tokenDecimals));
  const decimals = Number(Array.isArray(decimalsRaw) ? decimalsRaw[0] : decimalsRaw);
  const symbolRaw = JSON.parse(JSON.stringify(properties.tokenSymbol));
  const symbol = String(Array.isArray(symbolRaw) ? symbolRaw[0] : symbolRaw);
  if (!Number.isFinite(decimals) || decimals <= 0 || decimals > 36) {
    throw new Error(`bad tokenDecimals: got ${JSON.stringify(properties.tokenDecimals)} → resolved to ${decimals}`);
  }
  console.error(`[heima-paseo-sudo] resolved decimals=${decimals} symbol=${symbol}`);
  const amount = new BN(String(flags['amount-hei'])).mul(new BN(10).pow(new BN(decimals)));
  console.error(`[heima-paseo-sudo] transferring ${flags['amount-hei']} ${symbol} (=${amount.toString()} units)`);

  // Pre-check Alice's balance. force_transfer is sudo-authorized but still
  // requires the SOURCE (alice) to have sufficient free balance — sudo
  // bypasses origin checks, not balance checks. Without this preflight,
  // a low-Alice testnet (e.g. Paseo where Alice has been drained by
  // earlier testers) silently accepts the tx into the pool but no
  // validator includes it because the value can't be paid; signAndSend's
  // callback then never fires and the script timeouts opaquely after 60s.
  const aliceInfo = await api.query.system.account(alice.address);
  const aliceFree = new BN(aliceInfo.data.free.toString());
  const safetyMargin = new BN(10).pow(new BN(Math.max(decimals - 1, 0))); // 0.1 HEI for fees
  const aliceUsable = aliceFree.sub(safetyMargin);
  const aliceFreeHei = (Number(BigInt(aliceFree.toString()) / 10n ** BigInt(Math.max(decimals - 4, 0))) / 10000).toFixed(4);
  console.error(`[heima-paseo-sudo] Alice free balance = ${aliceFree.toString()} (~${aliceFreeHei} ${symbol})`);
  if (aliceUsable.lte(new BN(0))) {
    throw new Error(
      `Alice is out of ${symbol} on this chain (free=${aliceFree.toString()}, ` +
      `usable=${aliceUsable.toString()} after 0.1-${symbol} fee margin). ` +
      `Top her up before retrying. On the Heima Paseo testnet she shares ` +
      `with other testers, the funding source is the Heima dev team's faucet.`
    );
  }
  if (amount.gt(aliceUsable)) {
    throw new Error(
      `requested ${flags['amount-hei']} ${symbol} > Alice's usable balance ` +
      `(${aliceUsable.toString()} = ~${aliceFreeHei} ${symbol} - 0.1 ${symbol} fee margin). ` +
      `Reduce --amount-hei OR top Alice up.`
    );
  }

  const inner = api.tx.balances.forceTransfer(alice.address, recipientSubstrate, amount);
  const sudo = api.tx.sudo.sudo(inner);

  return new Promise((resolve, reject) => {
    // Resolve on `isInBlock` rather than `isFinalized`. Paseo finalization
    // can be 60s+ and is not strictly needed: the next read (e.g. eth_getBalance
    // probe in heima-paseo-bring-up.sh) sees the new balance as soon as the
    // block is mined. Finality is a stricter guarantee than this funding
    // step needs. Also: in past sessions the .mjs would hang indefinitely
    // when finality never fired, with no diagnostic.
    let unsub = null;
    const timeoutMs = 60_000;
    const timer = setTimeout(() => {
      if (unsub) try { unsub(); } catch (_) {}
      reject(new Error(`signAndSend timed out after ${timeoutMs}ms — neither isInBlock nor isFinalized arrived. Check the broker host / chain liveness.`));
    }, timeoutMs);

    // Pass a non-zero `tip` so a stuck (un-mined) tx with the same
    // (sender, nonce) in the mempool gets evicted. Substrate's pool
    // replacement rule requires the new tx's priority to be strictly
    // greater than the old's. Without a tip, retrying a fund after a
    // killed signAndSend fails with "Priority is too low: (X vs X)".
    // 1e9 attoHEI = 1 nanoHEI ≈ free; testnet so cost is irrelevant.
    sudo.signAndSend(alice, { tip: '1000000000' }, ({ status, dispatchError, events }) => {
      if (dispatchError) {
        clearTimeout(timer);
        if (unsub) try { unsub(); } catch (_) {}
        if (dispatchError.isModule) {
          const decoded = api.registry.findMetaError(dispatchError.asModule);
          reject(new Error(`dispatchError: ${decoded.section}.${decoded.name}: ${decoded.docs.join(' ')}`));
        } else {
          reject(new Error(`dispatchError: ${dispatchError.toString()}`));
        }
        return;
      }
      if (status.isInBlock) {
        clearTimeout(timer);
        const blockHash = status.asInBlock.toHex();
        console.error(`[heima-paseo-sudo] in block ${blockHash}`);
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
          in_block: blockHash,
        }, null, 2));
        if (unsub) try { unsub(); } catch (_) {}
        resolve();
      }
    })
    .then((u) => { unsub = u; })
    .catch((err) => { clearTimeout(timer); reject(err); });
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
    // Surface the message AND the stack — bn.js's "Assertion failed" by
    // itself is uninformative without the stack pointing at the offending
    // call site. Operators debugging without a stack hit dead ends.
    console.error(`[heima-paseo-sudo] ERROR: ${e.message}`);
    if (e.stack) console.error(e.stack);
    process.exit(1);
  }
  process.exit(0);
}

main();
