import { encodeAbiParameters, keccak256, type Address, type PublicClient } from "viem";
import { tenderAbi, vendorRegistryAbi } from "../abi.js";
import type { BidModel, CheckResult, ReconstructedTender } from "./model.js";

/** `keccak256(abi.encode(tender, vendorId))` (SPEC §5 tie rank), byte-for-byte. */
function tieRank(tender: Address, vendorId: bigint): bigint {
  const encoded = encodeAbiParameters([{ type: "address" }, { type: "uint64" }], [tender, vendorId]);
  return BigInt(keccak256(encoded));
}

/** Debarred-before-cutoff status for every bidder that ever committed (one registry read each). */
async function loadDebarment(
  client: PublicClient,
  model: ReconstructedTender,
): Promise<Map<Address, boolean>> {
  const out = new Map<Address, boolean>();
  for (const bid of model.bids.values()) {
    if (bid.state === "None") continue;
    const debarred = await client.readContract({
      address: model.config.registry,
      abi: vendorRegistryAbi,
      functionName: "isDebarredBefore",
      args: [bid.vendorId, model.config.schedule.priceRevealStart],
    });
    out.set(bid.bidder, debarred as boolean);
  }
  return out;
}

/** SPEC §5 ranking: Eligible, opened, not debarred-before-cutoff, sorted (price, tieRank). */
function computeRanking(model: ReconstructedTender, debarment: Map<Address, boolean>): Address[] {
  const candidates = [...model.bids.values()].filter(
    (b) => b.state === "Eligible" && b.opened && !debarment.get(b.bidder),
  );
  candidates.sort((x, y) => {
    if (x.price !== y.price) return x.price < y.price ? -1 : 1;
    const tx = tieRank(model.address, x.vendorId);
    const ty = tieRank(model.address, y.vendorId);
    return tx < ty ? -1 : tx > ty ? 1 : 0;
  });
  return candidates.map((b) => b.bidder);
}

type TerminalCause =
  | "None"
  | "AwardAccepted"
  | "CancelledByPE"
  | "NoBids"
  | "NoEligibleBids"
  | "NoRankedBids"
  | "AllOffersLapsed"
  | "UnresolvedAtPriceReveal";

/**
 * Mirrors `Tender._evaluate` (SPEC §4) using only independently reconstructed counts and
 * `nowTs` (the latest block's timestamp) -- never the contract's own `currentPhase()`.
 * Sound because once a tender is terminal, SPEC I10 forbids any further state change, so
 * "final reconstructed counts" equal "counts at the moment terminal-ness was reached" for
 * every one of these branches.
 */
function deriveTerminalCause(model: ReconstructedTender, ranked: Address[], nowTs: bigint): TerminalCause {
  if (model.cancelledByPE) return "CancelledByPE";
  if (model.accepted) return "AwardAccepted";

  const bids = [...model.bids.values()];
  const activeBidCount = bids.filter((b) => b.state !== "Withdrawn" && b.state !== "None").length;
  if (activeBidCount === 0) return "NoBids";

  const unresolvedCount = bids.filter((b) => b.state === "Revealed" || b.state === "Appealed").length;
  const eligibleCount = bids.filter((b) => b.state === "Eligible").length;

  if (nowTs < model.config.schedule.priceRevealStart) return "None"; // not yet terminal
  if (unresolvedCount > 0) return "UnresolvedAtPriceReveal";
  if (eligibleCount === 0) return "NoEligibleBids";
  if (nowTs < model.config.schedule.priceRevealEnd) return "None";

  if (ranked.length === 0) return "NoRankedBids";
  const lapseAt = model.config.schedule.priceRevealEnd + BigInt(ranked.length) * model.config.schedule.acceptanceWindow;
  if (nowTs < lapseAt) return "None";
  return "AllOffersLapsed";
}

function classifyExpectedSettlement(
  bid: BidModel,
  model: ReconstructedTender,
  cause: TerminalCause,
  debarredBeforeCutoff: boolean,
  ranked: Address[],
): { expected: "Refund" | "Forfeit"; code?: "F1" | "F2" | "F3" } {
  if (bid.state === "Withdrawn") return { expected: "Refund" };

  if (bid.state === "Committed") {
    const techRevealPassedBeforeEnd =
      !model.cancelledByPE || (model.cancelledAt ?? 0n) >= model.config.schedule.techRevealEnd;
    return techRevealPassedBeforeEnd ? { expected: "Forfeit", code: "F1" } : { expected: "Refund" };
  }

  if (bid.state === "Eligible" && !bid.opened && !debarredBeforeCutoff) {
    if (cause === "NoRankedBids" || cause === "AllOffersLapsed" || cause === "AwardAccepted") {
      return { expected: "Forfeit", code: "F2" };
    }
  }

  if (bid.state === "Eligible" && bid.opened && !debarredBeforeCutoff) {
    const i = ranked.indexOf(bid.bidder);
    if (i >= 0) {
      if (cause === "AllOffersLapsed") return { expected: "Forfeit", code: "F3" };
      if (cause === "AwardAccepted") {
        const w = model.winner ? ranked.indexOf(model.winner) : -1;
        if (w >= 0 && w > i) return { expected: "Forfeit", code: "F3" };
      }
    }
  }

  return { expected: "Refund" };
}

// ---------------------------------------------------------------------
// V1: PriceRevealed structural integrity
// ---------------------------------------------------------------------
// The verifier has no access to bidders' private salts, so it cannot re-derive
// priceCommitment from scratch (nor does it need to: the contract already rejects any
// revealPrice call whose (price, salt) doesn't hash to the recorded priceCommitment
// before PriceRevealed is ever emitted). What IS independently checkable from public
// data: every reveal belongs to a bid that had committed, was Eligible at the time, and
// reveals at most once.
function checkV1_PriceRevealIntegrity(model: ReconstructedTender): CheckResult {
  const details: string[] = [];
  let pass = true;
  const revealCounts = new Map<Address, number>();

  for (const ev of model.events) {
    if (ev.name !== "PriceRevealed") continue;
    const bidder = ev.args.bidder as Address;
    revealCounts.set(bidder, (revealCounts.get(bidder) ?? 0) + 1);
    const bid = model.bids.get(bidder);
    if (!bid || bid.priceCommitment === "0x") {
      pass = false;
      details.push(`${bidder}: PriceRevealed with no prior commitment on record`);
      continue;
    }
    if (ev.timestamp < model.config.schedule.priceRevealStart || ev.timestamp >= model.config.schedule.priceRevealEnd) {
      pass = false;
      details.push(`${bidder}: PriceRevealed at ts=${ev.timestamp}, outside [priceRevealStart, priceRevealEnd)`);
    }
  }
  for (const [bidder, count] of revealCounts) {
    if (count > 1) {
      pass = false;
      details.push(`${bidder}: revealed ${count} times (expected at most once)`);
    }
  }
  if (pass) details.push(`${revealCounts.size} reveal(s), each unique, each committed first, each within window`);
  return { id: "V1", name: "PriceRevealed structural integrity", pass, details };
}

// ---------------------------------------------------------------------
// V2: vote counts and threshold per bid
// ---------------------------------------------------------------------
function checkV2_VotesAndThreshold(model: ReconstructedTender): CheckResult {
  const details: string[] = [];
  let pass = true;
  const evaluatorSet = new Set(model.config.evaluators.map((e) => e.toLowerCase()));

  // Independently re-tally from raw VoteCast events (not model.bids' running counters).
  const tally = new Map<Address, { eligible: Set<Address>; ineligible: Set<Address> }>();
  for (const ev of model.events) {
    if (ev.name !== "VoteCast") continue;
    const bidder = ev.args.bidder as Address;
    const evaluator = ev.args.evaluator as Address;
    if (!evaluatorSet.has(evaluator.toLowerCase())) {
      pass = false;
      details.push(`${bidder}: vote from non-evaluator ${evaluator}`);
      continue;
    }
    let t = tally.get(bidder);
    if (!t) {
      t = { eligible: new Set(), ineligible: new Set() };
      tally.set(bidder, t);
    }
    const already = t.eligible.has(evaluator) || t.ineligible.has(evaluator);
    if (already) {
      pass = false;
      details.push(`${bidder}: evaluator ${evaluator} voted more than once`);
      continue;
    }
    (ev.args.eligible ? t.eligible : t.ineligible).add(evaluator);
  }

  for (const [bidder, t] of tally) {
    if (t.eligible.size >= model.config.threshold && t.ineligible.size >= model.config.threshold) {
      pass = false;
      details.push(`${bidder}: both eligible and ineligible reached threshold (I3 violated)`);
    }
    const bid = model.bids.get(bidder)!;
    const expectFinalized = t.eligible.size >= model.config.threshold || t.ineligible.size >= model.config.threshold;
    if (expectFinalized && bid.state !== "Eligible" && bid.state !== "Ineligible" && bid.state !== "Appealed") {
      pass = false;
      details.push(`${bidder}: reached threshold but final state is ${bid.state}`);
    }
  }
  if (pass) details.push(`${tally.size} bid(s) voted on; no double votes; threshold=${model.config.threshold} respected`);
  return { id: "V2", name: "Vote counts and threshold per bid", pass, details };
}

// ---------------------------------------------------------------------
// V3: appeals filed only by the bid's own owner
// ---------------------------------------------------------------------
function checkV3_AppealsByOwnerOnly(model: ReconstructedTender): CheckResult {
  const details: string[] = [];
  let pass = true;
  let count = 0;
  for (const ev of model.events) {
    if (ev.name !== "AppealFiled") continue;
    count++;
    const bidder = ev.args.bidder as Address;
    if (ev.txFrom.toLowerCase() !== bidder.toLowerCase()) {
      pass = false;
      details.push(`AppealFiled(bidder=${bidder}) but tx sender was ${ev.txFrom}`);
    }
  }
  if (pass) details.push(`${count} appeal(s), each filed by its own bid's tx sender`);
  return { id: "V3", name: "Appeals filed only by the bid's owner", pass, details };
}

// ---------------------------------------------------------------------
// V4: authority actions only on Escalated/Appealed bids, within window
// ---------------------------------------------------------------------
function checkV4_AuthorityActionsScoped(model: ReconstructedTender): CheckResult {
  const details: string[] = [];
  let pass = true;
  let count = 0;
  const authority = model.config.appealsAuthority.toLowerCase();

  for (const ev of model.events) {
    if (ev.name !== "EscalationResolved" && ev.name !== "AppealResolved") continue;
    count++;
    const bidder = ev.args.bidder as Address;
    if (ev.txFrom.toLowerCase() !== authority) {
      pass = false;
      details.push(`${ev.name}(${bidder}) sent by ${ev.txFrom}, not the appeals authority`);
    }
    const inWindow =
      ev.timestamp >= model.config.schedule.evaluationEnd && ev.timestamp < model.config.schedule.priceRevealStart;
    if (!inWindow) {
      pass = false;
      details.push(`${ev.name}(${bidder}) at ts=${ev.timestamp}, outside [evaluationEnd, priceRevealStart)`);
    }
    if (ev.name === "EscalationResolved" && ev.timestamp < model.config.schedule.evaluationEnd) {
      pass = false;
      details.push(`EscalationResolved(${bidder}) before evaluationEnd -- bid could not yet be Escalated`);
    }
  }
  if (pass) details.push(`${count} authority action(s), all from the appeals authority, all in-window`);
  return { id: "V4", name: "Authority actions scoped to Escalated/Appealed, in-window", pass, details };
}

// ---------------------------------------------------------------------
// V5: every action's block timestamp inside its phase
// ---------------------------------------------------------------------
function checkV5_ActionsInPhase(model: ReconstructedTender): CheckResult {
  const details: string[] = [];
  let pass = true;
  const s = model.config.schedule;
  let checked = 0;

  const require = (ok: boolean, label: string) => {
    checked++;
    if (!ok) {
      pass = false;
      details.push(label);
    }
  };

  for (const ev of model.events) {
    switch (ev.name) {
      case "BidCommitted":
      case "CommitmentReplaced":
      case "BidWithdrawn":
        require(ev.timestamp < s.submissionDeadline, `${ev.name} at ts=${ev.timestamp} not < submissionDeadline`);
        break;
      case "KeyEnvelopePosted":
        require(
          ev.timestamp >= s.submissionDeadline && ev.timestamp < s.techRevealEnd,
          `KeyEnvelopePosted at ts=${ev.timestamp} outside [submissionDeadline, techRevealEnd)`,
        );
        break;
      case "VoteCast":
        require(
          ev.timestamp >= s.techRevealEnd && ev.timestamp < s.evaluationEnd,
          `VoteCast at ts=${ev.timestamp} outside [techRevealEnd, evaluationEnd)`,
        );
        break;
      case "AppealFiled":
        require(
          ev.timestamp >= s.evaluationEnd && ev.timestamp < s.appealFilingEnd,
          `AppealFiled at ts=${ev.timestamp} outside [evaluationEnd, appealFilingEnd)`,
        );
        break;
      case "PriceRevealed":
        require(
          ev.timestamp >= s.priceRevealStart && ev.timestamp < s.priceRevealEnd,
          `PriceRevealed at ts=${ev.timestamp} outside [priceRevealStart, priceRevealEnd)`,
        );
        break;
      case "AwardAccepted":
        require(ev.timestamp >= s.priceRevealEnd, `AwardAccepted at ts=${ev.timestamp} not >= priceRevealEnd`);
        break;
      case "TenderCancelled":
        require(ev.timestamp < s.priceRevealStart, `TenderCancelled at ts=${ev.timestamp} not < priceRevealStart`);
        break;
      default:
        break; // EscalationResolved/AppealResolved covered by V4; DepositSettled has no fixed window.
    }
  }
  if (pass) details.push(`${checked} phase-restricted action(s) checked, all inside their required window`);
  return { id: "V5", name: "Every action's timestamp inside its required phase", pass, details };
}

// ---------------------------------------------------------------------
// V6: ranking and winner recomputed
// ---------------------------------------------------------------------
async function checkV6_RankingAndWinner(model: ReconstructedTender, client: PublicClient): Promise<CheckResult> {
  const details: string[] = [];
  let pass = true;
  const debarment = await loadDebarment(client, model);
  const ranked = computeRanking(model, debarment);

  const onChainRanking = (await client.readContract({
    address: model.address,
    abi: tenderAbi,
    functionName: "ranking",
  })) as Address[];

  if (onChainRanking.length !== ranked.length || !onChainRanking.every((a, i) => a.toLowerCase() === ranked[i]!.toLowerCase())) {
    pass = false;
    details.push(`recomputed ranking [${ranked.join(", ")}] != on-chain ranking() [${onChainRanking.join(", ")}]`);
  } else {
    details.push(`ranking() matches independent recomputation (${ranked.length} ranked bid(s))`);
  }

  if (model.accepted && model.winner && model.acceptedRound !== undefined) {
    const idx = Number(model.acceptedRound) - 1;
    const expectedOfferee = ranked[idx];
    if (!expectedOfferee || expectedOfferee.toLowerCase() !== model.winner.toLowerCase()) {
      pass = false;
      details.push(
        `AwardAccepted(round=${model.acceptedRound}, bidder=${model.winner}) but ranking[${idx}] = ${expectedOfferee ?? "none"}`,
      );
    } else {
      details.push(`winner ${model.winner} matches ranking[${idx}] for round ${model.acceptedRound}`);
    }
  }

  return { id: "V6", name: "Ranking and winner recomputed", pass, details };
}

// ---------------------------------------------------------------------
// V7: each DepositSettled matches SPEC §7, derived independently
// ---------------------------------------------------------------------
async function checkV7_SettlementsMatchSpec(model: ReconstructedTender, client: PublicClient): Promise<CheckResult> {
  const details: string[] = [];
  let pass = true;
  const debarment = await loadDebarment(client, model);
  const ranked = computeRanking(model, debarment);

  const latestBlock = await client.getBlock({ blockTag: "latest" });
  const cause = deriveTerminalCause(model, ranked, latestBlock.timestamp);

  let checked = 0;
  for (const bid of model.bids.values()) {
    if (!bid.settled) continue;
    checked++;
    const { expected, code } = classifyExpectedSettlement(bid, model, cause, debarment.get(bid.bidder) ?? false, ranked);
    const actualForfeited = bid.settledForfeited === true;
    const expectedForfeited = expected === "Forfeit";
    if (actualForfeited !== expectedForfeited) {
      pass = false;
      details.push(
        `${bid.bidder}: expected ${expected}${code ? ` (${code})` : ""}, on-chain DepositSettled.forfeited=${actualForfeited}`,
      );
      continue;
    }
    const expectedRecipient = expectedForfeited ? model.config.treasury : bid.bidder;
    if (bid.settledRecipient?.toLowerCase() !== expectedRecipient.toLowerCase()) {
      pass = false;
      details.push(`${bid.bidder}: expected recipient ${expectedRecipient}, got ${bid.settledRecipient}`);
      continue;
    }
    if (bid.settledAmount !== model.config.depositAmount) {
      pass = false;
      details.push(`${bid.bidder}: expected amount ${model.config.depositAmount}, got ${bid.settledAmount}`);
    }
  }
  if (pass) details.push(`terminal cause=${cause}; ${checked} settlement(s) all match SPEC §7`);
  return { id: "V7", name: "DepositSettled matches SPEC §7, derived independently", pass, details };
}

// ---------------------------------------------------------------------
// V8: accounting balance (I1)
// ---------------------------------------------------------------------
async function checkV8_AccountingBalance(model: ReconstructedTender, client: PublicClient): Promise<CheckResult> {
  const details: string[] = [];
  let pass = true;

  const commitCount = model.events.filter((e) => e.name === "BidCommitted").length;
  const depositsIn = BigInt(commitCount) * model.config.depositAmount;
  const settledOut = [...model.bids.values()].reduce((sum, b) => sum + (b.settledAmount ?? 0n), 0n);
  const expectedLiabilities = depositsIn - settledOut;

  const onChainLiabilities = (await client.readContract({
    address: model.address,
    abi: tenderAbi,
    functionName: "totalLiabilities",
  })) as bigint;

  if (expectedLiabilities !== onChainLiabilities) {
    pass = false;
    details.push(`expected totalLiabilities=${expectedLiabilities}, on-chain=${onChainLiabilities}`);
  } else {
    details.push(`totalLiabilities = ${depositsIn} deposited - ${settledOut} settled = ${expectedLiabilities}`);
  }

  const balance = (await client.readContract({
    address: model.config.token,
    abi: [
      {
        type: "function",
        name: "balanceOf",
        stateMutability: "view",
        inputs: [{ type: "address" }],
        outputs: [{ type: "uint256" }],
      },
    ],
    functionName: "balanceOf",
    args: [model.address],
  })) as bigint;

  if (balance < onChainLiabilities) {
    pass = false;
    details.push(`token.balanceOf(tender)=${balance} < totalLiabilities=${onChainLiabilities} (I1 violated)`);
  } else {
    details.push(`token.balanceOf(tender)=${balance} >= totalLiabilities=${onChainLiabilities}`);
  }

  return { id: "V8", name: "Accounting balance (I1)", pass, details };
}

export async function runAllChecks(model: ReconstructedTender, client: PublicClient): Promise<CheckResult[]> {
  return [
    checkV1_PriceRevealIntegrity(model),
    checkV2_VotesAndThreshold(model),
    checkV3_AppealsByOwnerOnly(model),
    checkV4_AuthorityActionsScoped(model),
    checkV5_ActionsInPhase(model),
    await checkV6_RankingAndWinner(model, client),
    await checkV7_SettlementsMatchSpec(model, client),
    await checkV8_AccountingBalance(model, client),
  ];
}
