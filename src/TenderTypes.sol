// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Order matters (I6): terminal phases (Final, Cancelled, Failed) sort after every
///      non-terminal phase, so the phase ordinal never decreases over time.
enum Phase {
    Open,
    TechReveal,
    Evaluation,
    AppealFiling,
    AppealResolution,
    PriceReveal,
    Acceptance,
    Final,
    Cancelled,
    Failed
}

enum BidState {
    None,
    Committed,
    Withdrawn,
    Revealed,
    Eligible,
    Ineligible,
    Appealed
}

enum TerminalCause {
    None,
    AwardAccepted,
    CancelledByPE,
    NoBids,
    NoEligibleBids,
    NoRankedBids,
    AllOffersLapsed,
    UnresolvedAtPriceReveal
}

enum Settlement {
    None,
    Pending,
    Refund,
    Forfeit,
    Settled
}

struct Bid {
    uint64 vendorId;
    BidState state;
    bytes32 priceCommitment;
    bytes32 docHash;
    bytes32 docCipherRef;
    bytes32 keyEnvelopeRef;
    uint8 eligibleVotes;
    uint8 ineligibleVotes;
    bool resolvedByAuthority; // verdict came from escalation resolution (not appealable)
    bool appealed; // bidder already used its one appeal
    bool opened;
    bool settled;
    uint256 price;
}
