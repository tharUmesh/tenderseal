import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, keccak256, toHex } from "viem";
import { computeCommitment } from "../src/crypto/commitment.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

test("computeCommitment reproduces the checked-in cross-language fixture", () => {
  const fixturePath = join(__dirname, "..", "fixtures", "commitment-vector.json");
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));

  const commitment = computeCommitment({
    chainId: BigInt(fixture.chainId),
    tender: fixture.tender,
    bidder: fixture.bidder,
    price: BigInt(fixture.price),
    docHash: fixture.docHash,
    salt: fixture.salt,
  });

  assert.equal(commitment, fixture.commitment);
});

test("computeCommitment is sensitive to every input (changing any one field changes the hash)", () => {
  const base = {
    chainId: 1n,
    tender: getAddress(keccak256(toHex("t")).slice(0, 42)),
    bidder: getAddress(keccak256(toHex("b")).slice(0, 42)),
    price: 100n,
    docHash: keccak256(toHex("doc")),
    salt: keccak256(toHex("salt")),
  };
  const baseline = computeCommitment(base);

  assert.notEqual(computeCommitment({ ...base, chainId: 2n }), baseline);
  assert.notEqual(computeCommitment({ ...base, tender: getAddress(keccak256(toHex("t2")).slice(0, 42)) }), baseline);
  assert.notEqual(computeCommitment({ ...base, bidder: getAddress(keccak256(toHex("b2")).slice(0, 42)) }), baseline);
  assert.notEqual(computeCommitment({ ...base, price: 101n }), baseline);
  assert.notEqual(computeCommitment({ ...base, docHash: keccak256(toHex("doc2")) }), baseline);
  assert.notEqual(computeCommitment({ ...base, salt: keccak256(toHex("salt2")) }), baseline);
});
