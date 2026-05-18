#!/usr/bin/env node
// derive-evm-from-mnemonic.mjs — read a BIP-39 mnemonic from a file
// path, derive the EVM keypair at the canonical BIP-44 path
// m/44'/60'/0'/0/0 (the same path MetaMask + ethers Wallet.fromPhrase
// + Foundry's `cast wallet --mnemonic-derivation-path` use), emit one
// line of JSON on stdout with {address, privateKey}.
//
// Status/diagnostic messages go to STDERR. The mnemonic and private
// key are NEVER echoed to stderr — only the public address is logged.
// The caller is responsible for stashing stdout securely (e.g. into
// a mode-0600 file).
//
// Usage:
//   node scripts/derive-evm-from-mnemonic.mjs <mnemonic-file-path>
//
// Example (bash caller):
//   JSON=$(node scripts/derive-evm-from-mnemonic.mjs ./test-hei)
//   ADDR=$(echo "$JSON" | jq -r .address)
//   PK=$(echo "$JSON" | jq -r .privateKey)
//   # Write the PK to a mode-0600 file; never echo $PK.
//
// Deps: ethers ^6 (in scripts/package.json).
//
// Also useful as a sanity check — pair with the substrate-side SS58
// derivation in this same directory to confirm a mnemonic produces
// the addresses you expect on both sides.

import { readFileSync } from 'node:fs';
import { Wallet } from 'ethers';

const path = process.argv[2];
if (!path) {
  console.error('usage: node derive-evm-from-mnemonic.mjs <path-to-mnemonic-file>');
  process.exit(1);
}
let mnemonic;
try {
  mnemonic = readFileSync(path, 'utf8').trim().split(/\s+/).join(' ');
} catch (e) {
  console.error(`ERROR reading ${path}: ${e.message}`);
  process.exit(1);
}
const wordCount = mnemonic.split(/\s+/).length;
if (![12, 15, 18, 21, 24].includes(wordCount)) {
  console.error(`ERROR: expected 12/15/18/21/24 BIP-39 words, got ${wordCount} in ${path}`);
  process.exit(1);
}

let wallet;
try {
  wallet = Wallet.fromPhrase(mnemonic);
} catch (e) {
  console.error(`ERROR deriving wallet from mnemonic at ${path}: ${e.message}`);
  console.error('(typically: mnemonic word list / checksum is invalid)');
  process.exit(1);
}
console.error(`[derive-evm-from-mnemonic] derived EVM address: ${wallet.address}`);
// Only the JSON goes to stdout — the caller captures it via $().
process.stdout.write(JSON.stringify({
  address: wallet.address,
  privateKey: wallet.privateKey,
}) + '\n');
