// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BidState, Phase} from "../../src/TenderTypes.sol";
import {TenderInvariantsBase} from "./TenderInvariantsBase.sol";

/// @dev Checkpoint suite (Step 7d): starts the SAME handler, exercising the SAME
///      invariant_I1..I12 checks as `TenderInvariantsTest`, from a fixed point at the
///      *start of AppealFiling* with mixed verdicts already on record: one Eligible
///      (bidder0), one Ineligible (bidder1), two still-Revealed bidders that become
///      Escalated the instant evaluationEnd passes (bidder2, with one stray eligible
///      vote; bidder3, with none), and one bidder that never posted its key envelope
///      (bidder4) -- so it is already ForfeitedF1 (derived) by this point. This puts the
///      fuzzer's full randomness budget right in front of AppealFiling/AppealResolution
///      (I3's escalation/appeal handling, I4's unresolved-at-priceRevealStart collapse)
///      instead of spending most of it reaching Evaluation at all.
///
///      `setUp` builds the checkpoint by calling ONLY the handler's own functions
///      (`commit`, `postKeyEnvelope`, `castVote`) -- never `TenderHarness` setters -- so
///      every vote is recorded in the shadow vote tallies and the three shadow counters
///      exactly as a real fuzzer sequence would leave them. `seed = 0` on every call is
///      deliberate (see `_buildCheckpoint`'s comment). Time is advanced with `vm.warp`
///      directly to land on the exact checkpoint timestamp; randomness then continues
///      unmodified.
///
/// forge-config: default.invariant.runs = 150
/// forge-config: default.invariant.depth = 200
contract TenderInvariantsCP2Test is TenderInvariantsBase {
    address internal b0;
    address internal b1;
    address internal b2;
    address internal b3;
    address internal b4;

    function setUp() public override {
        super.setUp();
        (address[] memory bidderAddrs,) = _deployTenderAndHandler();
        (b0, b1, b2, b3, b4) =
        (bidderAddrs[0], bidderAddrs[1], bidderAddrs[2], bidderAddrs[3], bidderAddrs[4]);
        _buildCheckpoint();
    }

    /// @dev `bidderSeed = 0` always targets the earliest-index bidder still in the wanted
    ///      shadow state, and `evalSeed = 0` always targets the earliest evaluator (in
    ///      construction order eval1/eval2/eval3) who hasn't yet voted on the currently
    ///      targeted bidder (`_evaluatorWhoHasntVoted`) -- so repeating 0 walks eval1 then
    ///      eval2 onto whichever bidder is first in the remaining Revealed set, without
    ///      needing per-call index arithmetic. b4 is deliberately never posted a key
    ///      envelope, so it stays Committed (-> ForfeitedF1 once techRevealEnd passes).
    function _buildCheckpoint() internal {
        for (uint256 i = 0; i < 5; i++) {
            handler.commit(0, i + 1, i, i);
        }

        vm.warp(handler.shadowSubmissionDeadline());
        for (uint256 i = 0; i < 4; i++) {
            handler.postKeyEnvelope(0); // b0, b1, b2, b3 -> Revealed; b4 left Committed
        }

        vm.warp(handler.shadowTechRevealEnd()); // Evaluation starts

        // b0 -> Eligible (2 eligible votes: eval1, eval2)
        handler.castVote(0, 0, true, 0);
        handler.castVote(0, 0, true, 0);
        // b1 -> Ineligible (2 ineligible votes: eval1, eval2)
        handler.castVote(0, 0, false, 2);
        handler.castVote(0, 0, false, 2);
        // b2 -> one stray eligible vote (eval1), never reaches threshold -> Escalated
        handler.castVote(0, 0, true, 0);
        // b3 -> no votes at all -> Escalated

        vm.warp(handler.shadowEvaluationEnd()); // AppealFiling starts
    }

    function test_checkpointReached() public view {
        assertEq(uint256(tender.currentPhase()), uint256(Phase.AppealFiling));
        assertEq(uint256(tender.getBid(b0).state), uint256(BidState.Eligible));
        assertEq(uint256(tender.getBid(b1).state), uint256(BidState.Ineligible));
        assertEq(uint256(tender.getBid(b2).state), uint256(BidState.Revealed)); // Escalated (derived)
        assertEq(uint256(tender.getBid(b3).state), uint256(BidState.Revealed)); // Escalated (derived)
        assertEq(uint256(tender.getBid(b4).state), uint256(BidState.Committed)); // ForfeitedF1 (derived)
        assertEq(handler.shadow_unresolvedCount(), 2); // b2, b3
        assertEq(handler.shadow_eligibleCount(), 1);
    }

    function _suiteTag() internal pure override returns (string memory) {
        return "CP2";
    }
}
