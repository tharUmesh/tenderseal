import type { Address, PublicClient } from "viem";
import { tenderAbi } from "../abi.js";
import type { BidModel, BidStateModel, EnrichedEvent, ReconstructedTender, TenderConfigModel } from "./model.js";

/**
 * Fetches every event the tender has ever emitted and independently replays them into the
 * same bid state machine `Tender.sol` implements (SPEC §4, §6) -- never by calling the
 * contract's own derived views (`getBid`, `currentPhase`, `ranking`, ...) for the state
 * being verified. Those views are only read later, by individual checks, to compare
 * against this independent reconstruction.
 */
export async function reconstructTender(
  client: PublicClient,
  tender: Address,
): Promise<ReconstructedTender> {
  const logs = await client.getContractEvents({
    address: tender,
    abi: tenderAbi,
    fromBlock: 0n,
    toBlock: "latest",
  });

  // Sort by (blockNumber, logIndex) so replay order matches on-chain execution order.
  logs.sort((a, b) => {
    if (a.blockNumber !== b.blockNumber) return a.blockNumber! < b.blockNumber! ? -1 : 1;
    return a.logIndex! - b.logIndex!;
  });

  const blockTimestampCache = new Map<bigint, bigint>();
  const txCache = new Map<string, { from: Address; to: Address | undefined; input: `0x${string}` }>();
  const events: EnrichedEvent[] = [];

  for (const log of logs) {
    const blockNumber = log.blockNumber!;
    let timestamp = blockTimestampCache.get(blockNumber);
    if (timestamp === undefined) {
      const block = await client.getBlock({ blockNumber });
      timestamp = block.timestamp;
      blockTimestampCache.set(blockNumber, timestamp);
    }

    const txHash = log.transactionHash!;
    let tx = txCache.get(txHash);
    if (tx === undefined) {
      const fetched = await client.getTransaction({ hash: txHash });
      tx = { from: fetched.from, to: fetched.to ?? undefined, input: fetched.input };
      txCache.set(txHash, tx);
    }

    events.push({
      name: log.eventName as string,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      args: log.args as any,
      blockNumber,
      timestamp,
      txFrom: tx.from,
      txTo: tx.to,
      txInput: tx.input,
      logIndex: log.logIndex!,
    });
  }

  const created = events.find((e) => e.name === "TenderCreated");
  if (!created) {
    throw new Error(`No TenderCreated event found for ${tender} -- is this address a real Tender?`);
  }
  const a = created.args as Record<string, unknown>;
  const schedule = a.schedule as {
    submissionDeadline: bigint;
    techRevealEnd: bigint;
    evaluationEnd: bigint;
    appealFilingEnd: bigint;
    priceRevealStart: bigint;
    priceRevealEnd: bigint;
    acceptanceWindow: bigint;
  };
  const config: TenderConfigModel = {
    registry: a.registry as Address,
    token: a.token as Address,
    pe: a.pe as Address,
    appealsAuthority: a.appealsAuthority as Address,
    treasury: a.treasury as Address,
    evaluators: a.evaluators as Address[],
    threshold: Number(a.threshold),
    depositAmount: a.depositAmount as bigint,
    maxBidders: Number(a.maxBidders),
    schedule: {
      submissionDeadline: schedule.submissionDeadline,
      techRevealEnd: schedule.techRevealEnd,
      evaluationEnd: schedule.evaluationEnd,
      appealFilingEnd: schedule.appealFilingEnd,
      priceRevealStart: schedule.priceRevealStart,
      priceRevealEnd: schedule.priceRevealEnd,
      acceptanceWindow: schedule.acceptanceWindow,
    },
    createdAt: a.createdAt as bigint,
  };

  const bids = new Map<Address, BidModel>();
  const bid = (addr: Address): BidModel => {
    let b = bids.get(addr);
    if (!b) {
      b = {
        bidder: addr,
        vendorId: 0n,
        state: "None",
        priceCommitment: "0x" as `0x${string}`,
        docHash: "0x" as `0x${string}`,
        eligibleVotes: 0,
        ineligibleVotes: 0,
        votedBy: new Map(),
        resolvedByAuthority: false,
        appealed: false,
        opened: false,
        price: 0n,
        settled: false,
      };
      bids.set(addr, b);
    }
    return b;
  };

  let cancelledByPE = false;
  let cancelledAt: bigint | undefined;
  let accepted = false;
  let winner: Address | undefined;
  let acceptedRound: bigint | undefined;

  const setState = (b: BidModel, s: BidStateModel) => {
    b.state = s;
  };

  for (const ev of events) {
    const args = ev.args;
    switch (ev.name) {
      case "BidCommitted": {
        const b = bid(args.bidder as Address);
        b.vendorId = args.vendorId as bigint;
        b.priceCommitment = args.priceCommitment as `0x${string}`;
        b.docHash = args.docHash as `0x${string}`;
        b.committedAt = ev.timestamp;
        setState(b, "Committed");
        break;
      }
      case "CommitmentReplaced": {
        const b = bid(args.bidder as Address);
        b.priceCommitment = args.priceCommitment as `0x${string}`;
        b.docHash = args.docHash as `0x${string}`;
        break;
      }
      case "BidWithdrawn": {
        const b = bid(args.bidder as Address);
        setState(b, "Withdrawn");
        break;
      }
      case "KeyEnvelopePosted": {
        const b = bid(args.bidder as Address);
        b.keyEnvelopePostedAt = ev.timestamp;
        setState(b, "Revealed");
        break;
      }
      case "VoteCast": {
        const b = bid(args.bidder as Address);
        const evaluator = args.evaluator as Address;
        b.votedBy.set(evaluator, true);
        if (args.eligible as boolean) b.eligibleVotes++;
        else b.ineligibleVotes++;
        break;
      }
      case "VerdictFinalized": {
        const b = bid(args.bidder as Address);
        setState(b, (args.eligible as boolean) ? "Eligible" : "Ineligible");
        b.verdictFinalizedAt = ev.timestamp;
        break;
      }
      case "AppealFiled": {
        const b = bid(args.bidder as Address);
        b.appealed = true;
        b.appealFiledAt = ev.timestamp;
        setState(b, "Appealed");
        break;
      }
      case "EscalationResolved": {
        const b = bid(args.bidder as Address);
        b.resolvedByAuthority = true;
        b.resolvedAt = ev.timestamp;
        setState(b, (args.eligible as boolean) ? "Eligible" : "Ineligible");
        break;
      }
      case "AppealResolved": {
        const b = bid(args.bidder as Address);
        b.resolvedAt = ev.timestamp;
        setState(b, (args.upheld as boolean) ? "Eligible" : "Ineligible");
        break;
      }
      case "TenderCancelled": {
        cancelledByPE = true;
        cancelledAt = ev.timestamp;
        break;
      }
      case "PriceRevealed": {
        const b = bid(args.bidder as Address);
        b.opened = true;
        b.price = args.price as bigint;
        b.revealedPriceAt = ev.timestamp;
        break;
      }
      case "AwardAccepted": {
        const b = bid(args.bidder as Address);
        accepted = true;
        winner = args.bidder as Address;
        acceptedRound = args.round as bigint;
        b.acceptedAt = ev.timestamp;
        break;
      }
      case "DepositSettled": {
        const b = bid(args.bidder as Address);
        b.settled = true;
        b.settledForfeited = args.forfeited as boolean;
        b.settledAmount = args.amount as bigint;
        b.settledRecipient = args.recipient as Address;
        b.settledAt = ev.timestamp;
        break;
      }
      default:
        break; // ConflictDeclared / AwardAcknowledged: event-only, nothing to fold in.
    }
  }

  return { address: tender, config, bids, cancelledByPE, cancelledAt, accepted, winner, acceptedRound, events };
}
