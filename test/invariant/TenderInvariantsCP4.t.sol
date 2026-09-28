// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BidState, Phase} from "../../src/TenderTypes.sol";
import {TenderInvariantsBase} from "./TenderInvariantsBase.sol";

/// @dev Checkpoint suite (Step 7d): starts the SAME handler, exercising the SAME
///      invariant_I1..I12 checks as `TenderInvariantsTest`, from a fixed point at
///      exactly `priceRevealEnd` with three opened, ranked Eligible bids (bidder0..
///      bidder2, ascending price so bidder0 is the offeree of round 1) plus one Eligible
///      bid that never opened (bidder3) and one Ineligible bid (bidder4). At
///      `t == priceRevealEnd`, `_evaluate()`'s `t < priceRevealEnd` check is already
///      false, so this checkpoint lands one instant into round 1 of Acceptance -- ranking
///      is locked in and bidder3 has permanently missed its only chance to open
///      (`revealPrice` only succeeds during PriceReveal), exactly the state F2/I12/award
///      correctness need. This puts the fuzzer's full randomness budget right in front of
///      the offer-round/acceptance/settlement machinery, the part of the lifecycle the
///      cold-start suite reaches least often.
///
///      `setUp` builds the checkpoint by calling ONLY the handler's own functions
///      (`commit`, `postKeyEnvelope`, `castVote`, `revealPrice`) -- never `TenderHarness`
///      setters. Time is advanced with `vm.warp` directly to land on the exact checkpoint
///      timestamp; randomness then continues unmodified.
///
/// forge-config: default.invariant.runs = 150
/// forge-config: default.invariant.depth = 80
contract TenderInvariantsCP4Test is TenderInvariantsBase {
    address internal b0; // ranked #1 (lowest price)
    address internal b1; // ranked #2
    address internal b2; // ranked #3
    address internal b3; // Eligible, never opened
    address internal b4; // Ineligible

    function setUp() public override {
        super.setUp();
        (address[] memory bidderAddrs,) = _deployTenderAndHandler();
        (b0, b1, b2, b3, b4) =
        (bidderAddrs[0], bidderAddrs[1], bidderAddrs[2], bidderAddrs[3], bidderAddrs[4]);
        _buildCheckpoint();
    }

    /// @dev Same finalization pattern as CP3 (all 5 verdicts final, no debarment here),
    ///      then three `revealPrice` calls during PriceReveal -- `bidderSeed = 0` always
    ///      targets the earliest-index still-unopened Eligible bidder, so three calls open
    ///      b0, b1, b2 in that order and leave b3 Eligible-but-unopened.
    function _buildCheckpoint() internal {
        for (uint256 i = 0; i < 5; i++) {
            handler.commit(0, i + 1, i, i); // ascending prices: b0=1 ... b4=5
        }

        vm.warp(handler.shadowSubmissionDeadline());
        for (uint256 i = 0; i < 5; i++) {
            handler.postKeyEnvelope(0);
        }

        vm.warp(handler.shadowTechRevealEnd()); // Evaluation starts

        for (uint256 i = 0; i < 4; i++) {
            handler.castVote(0, 0, true, 0); // eval1
            handler.castVote(0, 0, true, 0); // eval2 -> finalizes Eligible
        }
        handler.castVote(0, 0, false, 2); // eval1
        handler.castVote(0, 0, false, 2); // eval2 -> finalizes Ineligible

        vm.warp(handler.shadowPriceRevealStart()); // PriceReveal starts

        handler.revealPrice(0); // b0
        handler.revealPrice(0); // b1
        handler.revealPrice(0); // b2 (b3 left unopened)

        vm.warp(handler.shadowPriceRevealEnd()); // Acceptance round 1 starts
    }

    function test_checkpointReached() public view {
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Acceptance));
        assertEq(tender.rankedCount(), 3);
        assertTrue(tender.getBid(b0).opened);
        assertTrue(tender.getBid(b1).opened);
        assertTrue(tender.getBid(b2).opened);
        assertEq(uint256(tender.getBid(b3).state), uint256(BidState.Eligible));
        assertFalse(tender.getBid(b3).opened);
        assertEq(uint256(tender.getBid(b4).state), uint256(BidState.Ineligible));
        (uint256 round, address offeree,) = tender.currentOffer();
        assertEq(round, 1);
        assertEq(offeree, b0);
    }

    function _suiteTag() internal pure override returns (string memory) {
        return "CP4";
    }
}
