#!/usr/bin/env node
import { computeCommitment, type CommitmentInput } from "./crypto/commitment.js";
import { generateSalt } from "./crypto/salt.js";
import { getAddress, keccak256, toHex, type Hex } from "viem";

/** Deterministically derives a valid, correctly-checksummed dummy address from a label. */
function dummyAddress(label: string) {
  return getAddress(keccak256(toHex(label)).slice(0, 42));
}

/**
 * Demonstrates SPEC claim 1's caveat directly (SPEC §10 Step 9a item 2): without a salt,
 * the price commitment hides nothing meaningful -- an observer just enumerates every
 * plausible price and re-hashes. With the real 256-bit salt, the same search is
 * astronomically infeasible.
 */

const ZERO_SALT: Hex = `0x${"00".repeat(32)}`;
const MIN_RUPEES = 1_000_000n;
const MAX_RUPEES = 25_000_000n;
const PRICE_DECIMALS = 2n; // MockTLKR: 2 decimals (cents)
const CENTS_PER_RUPEE = 10n ** PRICE_DECIMALS;

interface SearchResult {
  found: boolean;
  priceRupees?: bigint;
  candidatesTried: number;
  elapsedMs: number;
}

/** Enumerates whole-rupee candidates in [minRupees, maxRupees] and re-hashes each one. */
function searchBySalt(
  targetCommitment: Hex,
  fixed: Omit<CommitmentInput, "price">,
  minRupees: bigint,
  maxRupees: bigint,
): SearchResult {
  const start = performance.now();
  let candidatesTried = 0;
  for (let rupees = minRupees; rupees <= maxRupees; rupees++) {
    candidatesTried++;
    const candidate = computeCommitment({ ...fixed, price: rupees * CENTS_PER_RUPEE });
    if (candidate === targetCommitment) {
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
  // log10(2^bits / hashesPerSec / secondsPerYear), done in floating point since the
  // result is only ever reported as an order of magnitude.
  const SECONDS_PER_YEAR = 365.25 * 24 * 3600;
  const log10Candidates = bits * Math.log10(2);
  const log10Years = log10Candidates - Math.log10(hashesPerSec) - Math.log10(SECONDS_PER_YEAR);
  const exponent = Math.floor(log10Years);
  const mantissa = Math.pow(10, log10Years - exponent);
  return `~${mantissa.toFixed(2)} x 10^${exponent} years`;
}

function main(): void {
  const chainId = 31337n;
  const tender = dummyAddress("tenderseal-bruteforce-demo-tender");
  const bidder = dummyAddress("tenderseal-bruteforce-demo-bidder");
  const docHash = "0x" + "ab".repeat(32) as Hex;

  const secretRupees = MIN_RUPEES + BigInt(Math.floor(Math.random() * Number(MAX_RUPEES - MIN_RUPEES)));
  console.log("== TenderSeal brute-force demo (SPEC claim 1's caveat) ==");
  console.log(`Secret price (unknown to the attacker): ${secretRupees} LKR`);
  console.log(`Salt: 0x${"00".repeat(32)} (deliberately weak -- no salt)`);

  const targetCommitment = computeCommitment({
    chainId,
    tender,
    bidder,
    docHash,
    salt: ZERO_SALT,
    price: secretRupees * CENTS_PER_RUPEE,
  });
  console.log(`Leaked commitment: ${targetCommitment}\n`);

  console.log(`Searching LKR ${MIN_RUPEES.toLocaleString()}-${MAX_RUPEES.toLocaleString()} (whole rupees)...`);
  const result = searchBySalt(targetCommitment, { chainId, tender, bidder, docHash, salt: ZERO_SALT }, MIN_RUPEES, MAX_RUPEES);

  const hashesPerSec = result.candidatesTried / (result.elapsedMs / 1000);
  console.log(
    result.found
      ? `RECOVERED: ${result.priceRupees} LKR (matches the secret price: ${result.priceRupees === secretRupees})`
      : "NOT FOUND (unexpected -- the secret price should be inside the search range)",
  );
  console.log(`Candidates tried: ${result.candidatesTried.toLocaleString()}`);
  console.log(`Time taken:       ${formatDuration(result.elapsedMs)}`);
  console.log(`Throughput:       ${Math.round(hashesPerSec).toLocaleString()} commitments/sec\n`);

  console.log("With the real 256-bit salt (SPEC §5), the same brute-force approach must");
  console.log("additionally guess the salt -- estimated search time at the same throughput:");
  console.log(`  ${estimateYearsForBits(256, hashesPerSec)}`);
  console.log("(for reference, the universe is about 1.4 x 10^10 years old)");

  // Prove the salted commitment is what a bidder would actually use, and that it's a
  // different value entirely from the zero-salt one above -- the salt is what does the
  // hiding, not the absence of a public formula.
  const realSalt = generateSalt();
  const realCommitment = computeCommitment({
    chainId,
    tender,
    bidder,
    docHash,
    salt: realSalt,
    price: secretRupees * CENTS_PER_RUPEE,
  });
  console.log(`\nSame price with a real salt (${realSalt}):`);
  console.log(`  commitment: ${realCommitment} (unrelated-looking to the zero-salt one above)`);
}

main();
