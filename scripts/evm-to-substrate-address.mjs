#!/usr/bin/env node
// evm-to-substrate-address.mjs — given an EVM address, compute the
// Substrate account it's mapped to under Heima's Frontier setup
// (HashedAddressMapping<BlakeTwo256>):
//
//     substrate_account = blake2_256("evm:" || eth_address_bytes)
//
// EVM-side `eth_getBalance(0x...)` reads the free balance of that
// substrate account. So to fund a Heima EVM address from a Substrate
// holder, you do a Substrate-side `balances.transferKeepAlive` to
// THAT account (NOT to the SS58 of the same mnemonic's sr25519 key
// — different account entirely).
//
// Usage:
//   node scripts/evm-to-substrate-address.mjs <0x_EVM_ADDRESS>
//   node scripts/evm-to-substrate-address.mjs 0xdE644936D5B7d5d42032fd08bbA42Fbbfd6663Bc
//
// Output (on stdout): three forms of the same account:
//   - raw 32-byte hex
//   - SS58 prefix 31 (Heima mainnet — paste this into Polkadot.js Apps)
//   - SS58 prefix 131 (Heima Paseo)
//   - SS58 prefix 42 (generic substrate)
//
// Output (on stderr): one short explainer line about the mapping.

import { Keyring } from '@polkadot/keyring';
import {
  blake2AsU8a,
  cryptoWaitReady,
  encodeAddress,
} from '@polkadot/util-crypto';
import { hexToU8a, u8aToHex } from '@polkadot/util';

await cryptoWaitReady();

const evmAddr = process.argv[2];
if (!evmAddr || !/^0x[0-9a-fA-F]{40}$/.test(evmAddr)) {
  console.error('usage: node evm-to-substrate-address.mjs <0xEVM_ADDRESS_40_HEX>');
  process.exit(1);
}
const ethBytes = hexToU8a(evmAddr.toLowerCase());
const prefix = new TextEncoder().encode('evm:');
const combined = new Uint8Array(prefix.length + ethBytes.length);
combined.set(prefix, 0);
combined.set(ethBytes, prefix.length);
const substrate32 = blake2AsU8a(combined, 256);

console.error(`[evm-to-substrate] HashedAddressMapping<BlakeTwo256>("evm:" || ${evmAddr}):`);

const rawHex = u8aToHex(substrate32);
console.log(JSON.stringify({
  evm_address: evmAddr,
  substrate_account_hex: rawHex,
  ss58_heima_mainnet: encodeAddress(substrate32, 31),
  ss58_heima_paseo: encodeAddress(substrate32, 131),
  ss58_generic: encodeAddress(substrate32, 42),
}, null, 2));
