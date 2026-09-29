import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeFunctionData, getAddress, keccak256, toHex, type PublicClient } from "viem";
import { tenderAbi } from "../src/abi.js";
import { computeCommitment } from "../src/crypto/commitment.js";
import { checkV1_PriceRevealIntegrity } from "../src/verifier/checks.js";
import type { BidModel, EnrichedEvent, ReconstructedTender, TenderConfigModel } from "../src/verifier/model.js";

/**
 * Unit tests for verifier check V1 (Step 9a-fix item 2): crafted `ReconstructedTender`
 * models and fake transaction calldata, rather than a live chain, so a genuine
 * commitment mismatch can be demonstrated at all -- the real Tender contract itself
 * rejects any revealPrice() call whose calldata doesn't satisfy the recorded
 * commitment, so a real on-chain FAIL is structurally impossible to produce; what's
 * being tested here is that V1's own detection logic correctly catches one when fed it.
 */

function dummyAddress(label: string) {
  return getAddress(keccak256(toHex(label)).slice(0, 42));
}

const CHAIN_ID = 31337n;
const TENDER = dummyAddress("verify-test-tender");
const BIDDER = dummyAddress("verify-test-bidder");
const DOC_HASH = keccak256(toHex("verify-test-doc"));
const PRICE = 42_000_00n;
const REAL_SALT = keccak256(toHex("verify-test-real-salt"));
const WRONG_SALT = keccak256(toHex("verify-test-wrong-salt"));

const REAL_COMMITMENT = computeCommitment({
  chainId: CHAIN_ID,
  tender: TENDER,
  bidder: BIDDER,
  price: PRICE,
  docHash: DOC_HASH,
  salt: REAL_SALT,
});

const SCHEDULE: TenderConfigModel["schedule"] = {
  submissionDeadline: 100n,
  techRevealEnd: 200n,
  evaluationEnd: 300n,
  appealFilingEnd: 400n,
  priceRevealStart: 500n,
  priceRevealEnd: 600n,
  acceptanceWindow: 60n,
};

function baseConfig(): TenderConfigModel {
  return {
    registry: dummyAddress("registry"),
    token: dummyAddress("token"),
    pe: dummyAddress("pe"),
    appealsAuthority: dummyAddress("authority"),
    treasury: dummyAddress("treasury"),
    evaluators: [dummyAddress("eval1"), dummyAddress("eval2"), dummyAddress("eval3")],
    threshold: 2,
    depositAmount: 1_000_00n,
    maxBidders: 20,
    schedule: SCHEDULE,
    createdAt: 1n,
  };
}

function baseBid(): BidModel {
  return {
    bidder: BIDDER,
    vendorId: 1n,
    state: "Eligible",
    priceCommitment: REAL_COMMITMENT,
    docHash: DOC_HASH,
    eligibleVotes: 2,
    ineligibleVotes: 0,
    votedBy: new Map(),
    resolvedByAuthority: false,
    appealed: false,
    opened: true,
    price: PRICE,
    settled: false,
  };
}

function revealEvent(overrides: Partial<EnrichedEvent>): EnrichedEvent {
  return {
    name: "PriceRevealed",
    args: { bidder: BIDDER, price: PRICE },
    blockNumber: 1n,
    timestamp: 550n, // inside [priceRevealStart, priceRevealEnd)
    txFrom: BIDDER,
    txTo: TENDER,
    txInput: encodeFunctionData({
      abi: tenderAbi,
      functionName: "revealPrice",
      args: [BIDDER, PRICE, REAL_SALT],
    }),
    logIndex: 0,
    ...overrides,
  };
}

function modelWith(event: EnrichedEvent): ReconstructedTender {
  const bids = new Map<`0x${string}`, BidModel>();
  bids.set(BIDDER, baseBid());
  return {
    address: TENDER,
    config: baseConfig(),
    bids,
    cancelledByPE: false,
    accepted: false,
    events: [event],
  };
}

// V1 only ever calls client.getChainId() -- a minimal stub suffices.
const stubClient = { getChainId: async () => Number(CHAIN_ID) } as unknown as PublicClient;

test("V1 PASS: a direct EOA reveal's calldata satisfies the recorded commitment", async () => {
  const model = modelWith(revealEvent({}));
  const v1 = await checkV1_PriceRevealIntegrity(model, stubClient);
  assert.equal(v1.pass, true);
  assert.equal(v1.unverifiable?.length ?? 0, 0);
});

test("V1 FAIL: a crafted mismatch (calldata salt does not satisfy the recorded commitment)", async () => {
  const event = revealEvent({
    txInput: encodeFunctionData({
      abi: tenderAbi,
      functionName: "revealPrice",
      args: [BIDDER, PRICE, WRONG_SALT], // does NOT hash to REAL_COMMITMENT
    }),
  });
  const model = modelWith(event);
  const v1 = await checkV1_PriceRevealIntegrity(model, stubClient);
  assert.equal(v1.pass, false);
  assert.ok(v1.details.some((d) => d.includes("recomputed commitment")));
});

test("V1 NOT_VERIFIABLE: a reveal relayed through another contract is not silently PASSed", async () => {
  const relayContract = dummyAddress("some-relay-contract");
  const event = revealEvent({ txTo: relayContract, txInput: "0xdeadbeef" });
  const model = modelWith(event);
  const v1 = await checkV1_PriceRevealIntegrity(model, stubClient);
  // Not a failure (nothing contradicts the recorded commitment) -- but MUST be flagged,
  // never counted as a confirmed PASS with zero caveats.
  assert.equal(v1.pass, true);
  assert.equal(v1.unverifiable?.length, 1);
  assert.ok(v1.unverifiable![0]!.includes("not the tender directly"));
});
