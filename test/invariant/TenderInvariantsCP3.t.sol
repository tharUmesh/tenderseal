// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BidState, Phase} from "../../src/TenderTypes.sol";
import {TenderInvariantsBase} from "./TenderInvariantsBase.sol";

/// @dev Checkpoint suite (Step 7d): starts the SAME handler, exercising the SAME
///      invariant_I1..I12 checks as `TenderInvariantsTest`, from a fixed point at the
///      *start of PriceReveal* with all five verdicts already final -- four Eligible
///      (bidder0..bidder3) and one Ineligible (bidder4) -- so `_unresolvedCount == 0` and
///      the tender did not collapse to Failed. One of the four Eligible vendors
///      (bidder2's) is debarred before priceRevealStart, so it is excluded from ranking
///      (I9) even though its bid state is Eligible. This puts the fuzzer's full
///      randomness budget right in front of the actual money-moving phases (opens,
///      offer rounds, acceptance, F2/F3 settlement), which the cold-start suite
///      (`TenderInvariantsTest`) reaches in well under 20% of its runs.
///
///      `setUp` builds the lifecycle checkpoint by calling ONLY the handler's own
///      functions (`commit`, `postKeyEnvelope`, `castVote`) -- never `TenderHarness`
///      setters. The debarment itself is not a Tender/handler action at all: it is
///      applied through the real `VendorRegistry.debarVendor` (registrar-only, exactly as
///      SPEC §2 requires), then reported to the handler via
///      `recordDebarredBeforeCutoff` so its shadow model (I2) stays faithful -- see that
///      function's doc comment in `TenderHandler`. Time is advanced with `vm.warp`
///      directly to land on the exact checkpoint timestamp; randomness then continues
///      unmodified.
///
/// forge-config: default.invariant.runs = 150
/// forge-config: default.invariant.depth = 120
contract TenderInvariantsCP3Test is TenderInvariantsBase {
    address internal b0;
    address internal b1;
    address internal b2; // debarred before priceRevealStart
    address internal b3;
    address internal b4; // Ineligible

    function setUp() public override {
        super.setUp();
        (address[] memory bidderAddrs, uint64[] memory vendorIds) = _deployTenderAndHandler();
        (b0, b1, b2, b3, b4) =
        (bidderAddrs[0], bidderAddrs[1], bidderAddrs[2], bidderAddrs[3], bidderAddrs[4]);
        _buildCheckpoint(vendorIds[2]);
    }

    /// @dev `bidderSeed = 0` always targets the earliest-index bidder still in the wanted
    ///      shadow state, and `evalSeed = 0` always targets the earliest evaluator who
    ///      hasn't yet voted on the currently targeted bidder -- see CP2's identical
    ///      comment. b0..b3 each get 2 eligible votes (eval1, eval2); b4 gets 2 ineligible
    ///      votes, so every bidder is finalized and none is left Revealed/Appealed.
    function _buildCheckpoint(uint64 vendorId2) internal {
        for (uint256 i = 0; i < 5; i++) {
            handler.commit(0, i + 1, i, i);
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

        vm.prank(registrar);
        registry.debarVendor(vendorId2, keccak256("debar-reason"));
        handler.recordDebarredBeforeCutoff(b2);

        vm.warp(handler.shadowPriceRevealStart()); // PriceReveal starts
    }

    function test_checkpointReached() public view {
        assertEq(uint256(tender.currentPhase()), uint256(Phase.PriceReveal));
        assertEq(uint256(tender.getBid(b0).state), uint256(BidState.Eligible));
        assertEq(uint256(tender.getBid(b1).state), uint256(BidState.Eligible));
        assertEq(uint256(tender.getBid(b2).state), uint256(BidState.Eligible));
        assertEq(uint256(tender.getBid(b3).state), uint256(BidState.Eligible));
        assertEq(uint256(tender.getBid(b4).state), uint256(BidState.Ineligible));
        assertTrue(registry.isDebarredBefore(tender.getBid(b2).vendorId, tender.priceRevealStart()));
        assertEq(handler.shadow_unresolvedCount(), 0);
        assertEq(handler.shadow_eligibleCount(), 4);
    }

    function _suiteTag() internal pure override returns (string memory) {
        return "CP3";
    }
}
