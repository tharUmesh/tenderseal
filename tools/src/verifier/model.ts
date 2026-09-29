import type { Address, Hex } from "viem";

/** Mirrors `TenderConfig`/`Schedule` (SPEC §3), read once from the `TenderCreated` event. */
export interface TenderConfigModel {
  registry: Address;
  token: Address;
  pe: Address;
  appealsAuthority: Address;
  treasury: Address;
  evaluators: Address[];
  threshold: number;
  depositAmount: bigint;
  maxBidders: number;
  schedule: {
    submissionDeadline: bigint;
    techRevealEnd: bigint;
    evaluationEnd: bigint;
    appealFilingEnd: bigint;
    priceRevealStart: bigint;
    priceRevealEnd: bigint;
    acceptanceWindow: bigint;
  };
  createdAt: bigint;
}

/** Mirrors `BidState` (SPEC §4). */
export type BidStateModel =
  | "None"
  | "Committed"
  | "Withdrawn"
  | "Revealed"
  | "Eligible"
  | "Ineligible"
  | "Appealed";

/** Everything the verifier independently reconstructs about one bid from events alone. */
export interface BidModel {
  bidder: Address;
  vendorId: bigint;
  state: BidStateModel;
  priceCommitment: Hex;
  docHash: Hex;
  eligibleVotes: number;
  ineligibleVotes: number;
  /** evaluator -> did they vote on this bid at all (any verdict). */
  votedBy: Map<Address, boolean>;
  resolvedByAuthority: boolean;
  appealed: boolean;
  opened: boolean;
  price: bigint;
  settled: boolean;
  settledForfeited?: boolean;
  settledAmount?: bigint;
  settledRecipient?: Address;
  // Timestamps (seconds) of each transition this bid went through, for phase-window checks.
  committedAt?: bigint;
  keyEnvelopePostedAt?: bigint;
  verdictFinalizedAt?: bigint;
  appealFiledAt?: bigint;
  resolvedAt?: bigint;
  revealedPriceAt?: bigint;
  acceptedAt?: bigint;
  settledAt?: bigint;
}

/** One decoded event, enriched with its block timestamp and originating transaction. */
export interface EnrichedEvent {
  name: string;
  args: Record<string, unknown>;
  blockNumber: bigint;
  timestamp: bigint;
  txFrom: Address;
  /** The transaction's direct call target -- `undefined` for a contract-creation tx. */
  txTo: Address | undefined;
  /** Raw calldata of the transaction that emitted this event. */
  txInput: Hex;
  logIndex: number;
}

export interface ReconstructedTender {
  address: Address;
  config: TenderConfigModel;
  bids: Map<Address, BidModel>;
  cancelledByPE: boolean;
  cancelledAt?: bigint;
  accepted: boolean;
  winner?: Address;
  acceptedRound?: bigint;
  events: EnrichedEvent[];
}

export interface CheckResult {
  id: string;
  name: string;
  pass: boolean;
  details: string[];
  /**
   * Items this check could not evaluate at all (e.g. a reveal relayed through a
   * contract, whose calldata isn't `revealPrice(...)`) -- reported distinctly, never
   * folded into `pass` as if they were confirmed PASSes.
   */
  unverifiable?: string[];
}
