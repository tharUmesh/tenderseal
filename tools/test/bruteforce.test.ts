import { test } from "node:test";
import assert from "node:assert/strict";
import { getAddress, keccak256, toHex, type Hex } from "viem";
import { computeCommitment } from "../src/crypto/commitment.js";

/**
 * Unit-tests the search logic itself over a small range (fast); `npm run bruteforce`
 * separately runs the full LKR 1,000,000-25,000,000 demo and reports real timings.
 */
test("a zero-salt commitment is recovered by exhaustive search over a small range", () => {
  const fixed = {
    chainId: 31337n,
    tender: getAddress(keccak256(toHex("t")).slice(0, 42)),
    bidder: getAddress(keccak256(toHex("b")).slice(0, 42)),
    docHash: keccak256(toHex("doc")),
    salt: `0x${"00".repeat(32)}` as Hex,
  };
  const secretPrice = 4242n;
  const target = computeCommitment({ ...fixed, price: secretPrice });

  let recovered: bigint | undefined;
  for (let price = 4000n; price <= 4500n; price++) {
    if (computeCommitment({ ...fixed, price }) === target) {
      recovered = price;
      break;
    }
  }
  assert.equal(recovered, secretPrice);
});

test("a salted commitment is NOT found by searching price alone (the salt is unknown)", () => {
  const fixed = {
    chainId: 31337n,
    tender: getAddress(keccak256(toHex("t")).slice(0, 42)),
    bidder: getAddress(keccak256(toHex("b")).slice(0, 42)),
    docHash: keccak256(toHex("doc")),
  };
  const secretPrice = 4242n;
  const realSalt = keccak256(toHex("a-real-secret-salt"));
  const target = computeCommitment({ ...fixed, price: secretPrice, salt: realSalt });

  const zeroSalt = `0x${"00".repeat(32)}` as Hex;
  let found = false;
  for (let price = 4000n; price <= 4500n; price++) {
    if (computeCommitment({ ...fixed, price, salt: zeroSalt }) === target) {
      found = true;
      break;
    }
  }
  assert.equal(found, false);
});
