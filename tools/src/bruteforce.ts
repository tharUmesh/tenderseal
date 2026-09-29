#!/usr/bin/env node
import { parseArgs } from "node:util";
import { keccak_256 } from "@noble/hashes/sha3";
import { getAddress, keccak256, toHex, type Address, type Hex } from "viem";
import { generateSalt } from "./crypto/salt.js";

/**
 * Demonstrates SPEC claim 1's caveat directly (SPEC §10 Step 9a item 2, sped up in
 * item 9a-fix item 3): without a salt, the price commitment hides nothing meaningful --
 * an observer just enumerates every plausible price and re-hashes. With the real 256-bit
 * salt, the same search is astronomically infeasible.
 *
 * The search loop hashes directly with `@noble/hashes`' `keccak_256` over a preallocated
 * 192-byte ABI-encoded buffer (chainId||tender||bidder||price||docHash||salt, each a
 * 32-byte word) instead of calling viem's `encodeAbiParameters`/`keccak256` per
 * candidate: only the `price` word (bytes 96-127) changes between iterations, so the
 * other five words are written once and reused, and the hash itself uses a raw
 * Uint8Array in and out rather than round-tripping through hex strings.
 */

const ZERO_SALT: Hex = `0x${"00".repeat(32)}`;
const MIN_RUPEES = 1_000_000n;
const MAX_RUPEES = 25_000_000n;
const PRICE_DECIMALS = 2n; // MockTLKR: 2 decimals (cents)
const CENTS_PER_RUPEE = 10n ** PRICE_DECIMALS;

/** Deterministically derives a valid, correctly-checksummed dummy address from a label. */
function dummyAddress(label: string) {
  return getAddress(keccak256(toHex(label)).slice(0, 42));
}

function addressToWord(addr: Address): Buffer {
  const word = Buffer.alloc(32);
  Buffer.from(addr.slice(2), "hex").copy(word, 12);
  return word;
}

function bytes32ToWord(hex: Hex): Buffer {
  const word = Buffer.from(hex.slice(2), "hex");
  if (word.length !== 32) throw new Error(`expected a 32-byte value, got ${word.length} bytes: ${hex}`);
  return word;
}

/** Writes `value` as a 32-byte big-endian word directly into `buf` at `offset`. */
function writeUintWordInto(buf: Buffer, offset: number, value: bigint): void {
  let v = value;
  for (let i = offset + 31; i >= offset; i--) {
    buf[i] = Number(v & 0xffn);
    v >>= 8n;
  }
}

interface FixedFields {
  chainId: bigint;
  tender: Address;
  bidder: Address;
  docHash: Hex;
  salt: Hex;
}

interface SearchResult {
  found: boolean;
  priceRupees?: bigint;
  candidatesTried: number;
  elapsedMs: number;
}

/** Enumerates rupee candidates in [minRupees, maxRupees] stepping by `stepRupees`. */
function fastSearch(
  targetCommitment: Hex,
  fixed: FixedFields,
  minRupees: bigint,
  maxRupees: bigint,
  stepRupees: bigint,
): SearchResult {
  const buf = Buffer.alloc(192);
  writeUintWordInto(buf, 0, fixed.chainId);
  addressToWord(fixed.tender).copy(buf, 32);
  addressToWord(fixed.bidder).copy(buf, 64);
  // bytes 96-127 (price) are written fresh every iteration below.
  bytes32ToWord(fixed.docHash).copy(buf, 128);
  bytes32ToWord(fixed.salt).copy(buf, 160);

  const targetBytes = Buffer.from(targetCommitment.slice(2), "hex");

  const start = performance.now();
  let candidatesTried = 0;
  for (let rupees = minRupees; rupees <= maxRupees; rupees += stepRupees) {
    candidatesTried++;
    writeUintWordInto(buf, 96, rupees * CENTS_PER_RUPEE);
    const hash = keccak_256(buf);
    if (Buffer.compare(hash, targetBytes) === 0) {
      return { found: true, priceRupees: rupees, candidatesTried, elapsedMs: performance.now() - start };
    }
  }
  return { found: false, candidatesTried, elapsedMs: performance.now() - start };
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms.toFixed(1)} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

/** Order-of-magnitude "years" estimate for searching a `bits`-bit space at `hashesPerSec`. */
function estimateYearsForBits(bits: number, hashesPerSec: number): string {
  const SECONDS_PER_YEAR = 365.25 * 24 * 3600;
  const log10Candidates = bits * Math.log10(2);
  const log10Years = log10Candidates - Math.log10(hashesPerSec) - Math.log10(SECONDS_PER_YEAR);
  const exponent = Math.floor(log10Years);
  const mantissa = Math.pow(10, log10Years - exponent);
  return `~${mantissa.toFixed(2)} x 10^${exponent} years`;
}

function runDemo(stepRupees: bigint, label: string, fixed: FixedFields): void {
  const rangeSteps = (MAX_RUPEES - MIN_RUPEES) / stepRupees;
  const secretRupees = MIN_RUPEES + stepRupees * BigInt(Math.floor(Math.random() * Number(rangeSteps)));

  console.log(`\n-- ${label} (step = LKR ${stepRupees.toLocaleString()}) --`);
  console.log(`Secret price (unknown to the attacker): ${secretRupees} LKR`);

  const targetCommitment = fastCommitment(fixed, secretRupees * CENTS_PER_RUPEE);
  console.log(`Leaked commitment: ${targetCommitment}`);

  const approxCandidates = (MAX_RUPEES - MIN_RUPEES) / stepRupees + 1n;
  console.log(
    `Searching LKR ${MIN_RUPEES.toLocaleString()}-${MAX_RUPEES.toLocaleString()} in steps of ${stepRupees.toLocaleString()} (~${approxCandidates.toLocaleString()} candidates)...`,
  );
  const result = fastSearch(targetCommitment, fixed, MIN_RUPEES, MAX_RUPEES, stepRupees);

  const hashesPerSec = result.candidatesTried / (result.elapsedMs / 1000);
  console.log(
    result.found
      ? `RECOVERED: ${result.priceRupees} LKR (matches the secret price: ${result.priceRupees === secretRupees})`
      : "NOT FOUND (unexpected -- the secret price should be inside the search range)",
  );
  console.log(`Candidates tried: ${result.candidatesTried.toLocaleString()}`);
  console.log(`Time taken:       ${formatDuration(result.elapsedMs)}`);
  console.log(`Throughput:       ${Math.round(hashesPerSec).toLocaleString()} commitments/sec`);
}

/** Same 192-byte-buffer approach as fastSearch, for one-off commitments outside the loop. */
function fastCommitment(fixed: FixedFields, price: bigint): Hex {
  const buf = Buffer.alloc(192);
  writeUintWordInto(buf, 0, fixed.chainId);
  addressToWord(fixed.tender).copy(buf, 32);
  addressToWord(fixed.bidder).copy(buf, 64);
  writeUintWordInto(buf, 96, price);
  bytes32ToWord(fixed.docHash).copy(buf, 128);
  bytes32ToWord(fixed.salt).copy(buf, 160);
  return `0x${Buffer.from(keccak_256(buf)).toString("hex")}` as Hex;
}

function main(): void {
  const { values } = parseArgs({ options: { step: { type: "string", default: "1" } } });
  const step = BigInt(values.step ?? "1");
  if (step < 1n) throw new Error("--step must be >= 1");

  const chainId = 31337n;
  const tender = dummyAddress("tenderseal-bruteforce-demo-tender");
  const bidder = dummyAddress("tenderseal-bruteforce-demo-bidder");
  const docHash = ("0x" + "ab".repeat(32)) as Hex;
  const fixedZeroSalt: FixedFields = { chainId, tender, bidder, docHash, salt: ZERO_SALT };

  console.log("== TenderSeal brute-force demo (SPEC claim 1's caveat) ==");
  console.log("Salt: 0x00...00 (deliberately weak -- no salt) for every run below.");

  runDemo(1n, "Every whole rupee", fixedZeroSalt);

  let hashesPerSecForEstimate = 0;
  {
    // Re-time a plain (step=1) run's throughput specifically for the salt-search
    // estimate below, independent of which --step the CLI was invoked with.
    const probe = fastSearch(
      fastCommitment(fixedZeroSalt, MIN_RUPEES * CENTS_PER_RUPEE),
      fixedZeroSalt,
      MIN_RUPEES,
      MIN_RUPEES + 200_000n,
      1n,
    );
    hashesPerSecForEstimate = probe.candidatesTried / (probe.elapsedMs / 1000);
  }

  if (step !== 1n) {
    runDemo(step, `Rounded to the nearest LKR ${step.toLocaleString()} (--step ${step})`, fixedZeroSalt);
  }

  console.log("\nWith the real 256-bit salt (SPEC §5), the same brute-force approach must");
  console.log("additionally guess the salt -- estimated search time for the full 2^256 space:");
  console.log(
    `  at this run's own measured throughput (~${Math.round(hashesPerSecForEstimate).toLocaleString()}/sec): ${estimateYearsForBits(256, hashesPerSecForEstimate)}`,
  );
  console.log(
    `  at an assumed GPU-class attacker (1e9 hashes/sec, LABELED assumption, not measured here): ${estimateYearsForBits(256, 1e9)}`,
  );
  console.log("(for reference, the universe is about 1.4 x 10^10 years old)");

  // Prove the salted commitment is what a bidder would actually use, and that it's a
  // different value entirely from the zero-salt one above -- the salt is what does the
  // hiding, not the absence of a public formula.
  const realSalt = generateSalt();
  const secretRupees = MIN_RUPEES + BigInt(Math.floor(Math.random() * Number(MAX_RUPEES - MIN_RUPEES)));
  const realCommitment = fastCommitment(
    { ...fixedZeroSalt, salt: realSalt },
    secretRupees * CENTS_PER_RUPEE,
  );
  console.log(`\nSame price (${secretRupees} LKR) with a real salt (${realSalt}):`);
  console.log(`  commitment: ${realCommitment} (unrelated-looking to any zero-salt commitment above)`);
}

main();
