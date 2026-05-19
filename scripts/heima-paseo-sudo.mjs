#!/usr/bin/env node
// heima-paseo-sudo.mjs — Node helper that wraps pallet_sudo on Heima Paseo
// for AgentKeys stage-1 bring-up tasks. PASEO ONLY — refuses to run against
// Heima mainnet (chain ID 212013) because mainnet has no sudo and any call
// would either fail or, worse, hit some leftover testnet hook.
//
// Subcommands:
//   fund         — sudo-transfer HEI from Alice to a target EVM address.
//                  Auto-tops-up Alice via forceSetBalance if she's low
//                  before submitting the transfer.
//   top-up-alice — sudo-mint HEI directly to Alice via balances.forceSetBalance.
//                  Idempotent: refuses to lower her balance if she's already
//                  above --target-hei. Useful when Alice has been drained
//                  by other testers on the shared Paseo testnet.
//   bootstrap    — sudo-wrap a Substrate or EVM extrinsic for one-shot bootstrap
//                  (e.g., set K3EpochCounter signer governance, force-set scope)
//   whoami       — print the sudo key's SS58 (under Heima prefix 31) for sanity
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

// Shared signAndSend wrapper: passes a 1-nanoHEI tip so stuck mempool
// txs get evicted, resolves on `isInBlock` (Paseo finalization can be
// 60s+ and isn't needed for our use case — subsequent reads see the
// block as soon as it's mined), 60s hard timeout so the script can
// never hang opaquely. Used by cmdFund AND cmdTopUpAlice.
async function signAndSendAsAliceWithTip(api, alice, call, label) {
  return new Promise((resolve, reject) => {
    let unsub = null;
    const timeoutMs = 60_000;
    const timer = setTimeout(() => {
      if (unsub) try { unsub(); } catch (_) {}
      reject(new Error(`${label}: signAndSend timed out after ${timeoutMs}ms — chain liveness?`));
    }, timeoutMs);
    // Tip: bumped to 1e15 attoHEI = 0.001 HEI = ~1M× the substrate
    // mempool's default tip floor. A previous (stuck) tx in the pool
    // at the same (sender, nonce) gets evicted only if our priority
    // is meaningfully higher — pool replacement requires
    // `new.priority > old.priority` plus an internal threshold. A
    // 1-nanoHEI tip turned out to be too small to overcome a stuck
    // tx that was itself submitted with the same nano-tip; 1e15
    // gives generous headroom. Cost is irrelevant on testnet.
    call.signAndSend(alice, { tip: '1000000000000000' }, ({ status, dispatchError, events }) => {
      if (dispatchError) {
        clearTimeout(timer);
        if (unsub) try { unsub(); } catch (_) {}
        if (dispatchError.isModule) {
          const decoded = api.registry.findMetaError(dispatchError.asModule);
          reject(new Error(`${label}: dispatchError: ${decoded.section}.${decoded.name}: ${decoded.docs.join(' ')}`));
        } else {
          reject(new Error(`${label}: dispatchError: ${dispatchError.toString()}`));
        }
        return;
      }
      if (status.isInBlock) {
        clearTimeout(timer);
        const blockHash = status.asInBlock.toHex();
        console.error(`[heima-paseo-sudo] ${label}: in block ${blockHash}`);
        for (const { event } of events) {
          if (event.section === 'sudo' && event.method === 'Sudid') {
            const result = event.data.toJSON()[0];
            console.error(`[heima-paseo-sudo] ${label}: sudo.Sudid: ${JSON.stringify(result)}`);
          }
        }
        if (unsub) try { unsub(); } catch (_) {}
        resolve(blockHash);
      }
    })
    .then((u) => { unsub = u; })
    .catch((err) => { clearTimeout(timer); reject(err); });
  });
}

// Extract { decimals, symbol } from chain.system_properties, handling
// the array-wrapping codec quirk (Vec<u32> sometimes round-trips as
// [18] sometimes as a polkadot codec; .toJSON()+JSON-roundtrip
// normalizes both to plain JS arrays).
function chainTokenInfo(properties) {
  const decimalsRaw = JSON.parse(JSON.stringify(properties.tokenDecimals));
  const decimals = Number(Array.isArray(decimalsRaw) ? decimalsRaw[0] : decimalsRaw);
  const symbolRaw = JSON.parse(JSON.stringify(properties.tokenSymbol));
  const symbol = String(Array.isArray(symbolRaw) ? symbolRaw[0] : symbolRaw);
  if (!Number.isFinite(decimals) || decimals <= 0 || decimals > 36) {
    throw new Error(`bad tokenDecimals: got ${JSON.stringify(properties.tokenDecimals)} → resolved to ${decimals}`);
  }
  return { decimals, symbol };
}

// Format a BN amount (in attoHEI) as a human-readable string.
function humanize(amountBN, decimals) {
  const divisor = 10n ** BigInt(Math.max(decimals - 4, 0));
  return (Number(BigInt(amountBN.toString()) / divisor) / 10000).toFixed(4);
}

// Ensure Alice has at least `requestedAmount + 0.1 fee margin`. If she
// doesn't, sudo-mint into her account via `balances.forceSetBalance`
// (Alice can sudo any pallet call — she's the sudoer). Target is
// max(requested * 100, 1000 HEI) so subsequent runs reuse the inflated
// balance and don't re-mint every time.
//
// Returns true if top-up fired, false if Alice already had enough.
//
// Why this works: Alice is the sudoer on Heima Paseo. sudo.sudo(call)
// dispatches `call` as if from Root origin. balances.forceSetBalance
// takes (who, new_free) and sets `who`'s free balance directly — this
// effectively mints new tokens (total issuance climbs, but that's
// fine for a testnet shared by N testers who keep draining each
// other's Alice balance). See `agentkeys chain show heima-paseo |
// jq .dev_environment.sudo` for the Alice-as-sudoer doc.
async function ensureAliceCanFund(api, alice, decimals, symbol, requestedAmount) {
  const { BN } = polkadotUtil;
  const aliceInfo = await api.query.system.account(alice.address);
  const aliceFree = new BN(aliceInfo.data.free.toString());
  const safetyMargin = new BN(10).pow(new BN(Math.max(decimals - 1, 0))); // 0.1 HEI fee margin
  const aliceUsable = aliceFree.sub(safetyMargin);
  const usableForLog = aliceUsable.lt(new BN(0)) ? new BN(0) : aliceUsable;
  console.error(`[heima-paseo-sudo] Alice free = ${humanize(aliceFree, decimals)} ${symbol} (usable after 0.1-${symbol} fee margin: ${humanize(usableForLog, decimals)})`);
  if (aliceUsable.gte(requestedAmount)) {
    return false;
  }
  // Need to top up. Target = max(requested * 100, 1000 native units).
  const oneThousand = new BN(1000).mul(new BN(10).pow(new BN(decimals)));
  const requestedX100 = requestedAmount.muln(100);
  const target = BN.max(requestedX100, oneThousand);
  console.error(`[heima-paseo-sudo] Alice short (~${humanize(aliceFree, decimals)} ${symbol}, need ~${humanize(requestedAmount, decimals)}). Sudo-minting Alice to ${humanize(target, decimals)} ${symbol} via balances.forceSetBalance …`);
  const setBal = api.tx.balances.forceSetBalance(alice.address, target);
  const sudoCall = api.tx.sudo.sudo(setBal);
  await signAndSendAsAliceWithTip(api, alice, sudoCall, 'top-up-alice');
  const reread = await api.query.system.account(alice.address);
  const aliceNewFree = new BN(reread.data.free.toString());
  console.error(`[heima-paseo-sudo] post-top-up Alice free = ${humanize(aliceNewFree, decimals)} ${symbol}`);
  return true;
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
  const { decimals, symbol } = chainTokenInfo(properties);
  const amount = new BN(String(flags['amount-hei'])).mul(new BN(10).pow(new BN(decimals)));
  console.error(`[heima-paseo-sudo] transferring ${flags['amount-hei']} ${symbol} (= ${humanize(amount, decimals)} ${symbol} = ${amount.toString()} atto-units)`);

  // Auto-top-up Alice if she can't cover this transfer. Idempotent: skips
  // if Alice already has enough. The CURRENT bring-up's only sudoer (Alice
  // on Paseo) can be drained by other testers using the shared testnet;
  // since she's the sudoer, she can also `forceSetBalance(alice, BIG)`
  // to refill herself. See ensureAliceCanFund's docstring.
  await ensureAliceCanFund(api, alice, decimals, symbol, amount);

  // Now the actual cross-account transfer.
  const inner = api.tx.balances.forceTransfer(alice.address, recipientSubstrate, amount);
  const sudo = api.tx.sudo.sudo(inner);
  const blockHash = await signAndSendAsAliceWithTip(api, alice, sudo, 'fund-deployer');
  console.log(JSON.stringify({
    ok: true,
    recipient_evm: flags.recipient,
    recipient_substrate: recipientSubstrate,
    amount_hei: flags['amount-hei'],
    in_block: blockHash,
  }, null, 2));
}

async function cmdTopUpAlice(flags) {
  const profile = loadProfile();
  const { api, properties } = await connect(profile);
  const alice = aliceKeyring(properties.ss58Format);
  console.error(`[heima-paseo-sudo] Alice SS58 (prefix ${properties.ss58Format}): ${alice.address}`);

  const { BN } = polkadotUtil;
  const { decimals, symbol } = chainTokenInfo(properties);
  const targetHeiStr = String(flags['target-hei'] || '1000');
  const target = new BN(targetHeiStr).mul(new BN(10).pow(new BN(decimals)));

  const aliceInfo = await api.query.system.account(alice.address);
  const aliceFree = new BN(aliceInfo.data.free.toString());
  console.error(`[heima-paseo-sudo] Alice current free = ${humanize(aliceFree, decimals)} ${symbol}`);

  if (aliceFree.gte(target)) {
    console.error(`[heima-paseo-sudo] Alice already has >= target (${humanize(target, decimals)} ${symbol}); refusing to lower her balance via forceSetBalance.`);
    console.log(JSON.stringify({
      ok: true,
      skipped: 'already-above-target',
      alice_ss58: alice.address,
      alice_free: aliceFree.toString(),
      alice_free_human: humanize(aliceFree, decimals) + ' ' + symbol,
      target_hei: targetHeiStr,
    }, null, 2));
    return;
  }

  console.error(`[heima-paseo-sudo] sudo-minting Alice from ${humanize(aliceFree, decimals)} → ${humanize(target, decimals)} ${symbol} via balances.forceSetBalance …`);
  const setBal = api.tx.balances.forceSetBalance(alice.address, target);
  const sudoCall = api.tx.sudo.sudo(setBal);
  const blockHash = await signAndSendAsAliceWithTip(api, alice, sudoCall, 'top-up-alice');

  const reread = await api.query.system.account(alice.address);
  const aliceNewFree = new BN(reread.data.free.toString());
  console.log(JSON.stringify({
    ok: true,
    alice_ss58: alice.address,
    target_hei: targetHeiStr,
    in_block: blockHash,
    alice_free_before: aliceFree.toString(),
    alice_free_after: aliceNewFree.toString(),
    alice_free_after_human: humanize(aliceNewFree, decimals) + ' ' + symbol,
  }, null, 2));
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
      case 'fund':         await cmdFund(flags); break;
      case 'top-up-alice': await cmdTopUpAlice(flags); break;
      case 'bootstrap':    await cmdBootstrap(flags); break;
      case 'whoami':       await cmdWhoami(); break;
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
