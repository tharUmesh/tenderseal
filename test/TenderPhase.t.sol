// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BidState, Phase, TerminalCause} from "../src/TenderTypes.sol";
import {TenderHarness} from "./harness/TenderHarness.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `_evaluate` / `currentPhase` / `terminalCause` / `rankedCount` tests (SPEC §4, §5).
///      Uses TenderHarness to set recorded facts directly, since the functions that
///      normally produce them (commit, castVote, ...) do not exist until later steps.
contract TenderPhaseTest is TenderTestBase {
    TenderHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new TenderHarness(_defaultConfig());
    }

    function _isTerminal(Phase p) internal pure returns (bool) {
        return p == Phase.Final || p == Phase.Cancelled || p == Phase.Failed;
    }

    // ------------------------------------------------------------------ Open -> NoBids

    function test_Phase_NoActiveBids_CancelledAtSubmissionDeadline() public {
        vm.warp(h.submissionDeadline() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Open));

        vm.warp(h.submissionDeadline());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoBids));

        vm.warp(h.submissionDeadline() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
    }

    // ------------------------------------------------------------------ Open -> TechReveal

    function test_Phase_OpenToTechReveal_AtSubmissionDeadline() public {
        h.h_setCounts(1, 0, 0);

        vm.warp(h.submissionDeadline() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Open));

        vm.warp(h.submissionDeadline());
        assertEq(uint256(h.currentPhase()), uint256(Phase.TechReveal));

        vm.warp(h.submissionDeadline() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.TechReveal));
    }

    // ------------------------------------------------------------------ TechReveal -> Evaluation

    function test_Phase_TechRevealToEvaluation_AtTechRevealEnd() public {
        h.h_setCounts(1, 0, 0);

        vm.warp(h.techRevealEnd() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.TechReveal));

        vm.warp(h.techRevealEnd());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Evaluation));

        vm.warp(h.techRevealEnd() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Evaluation));
    }

    // ------------------------------------------------------------------ Evaluation -> AppealFiling

    function test_Phase_EvaluationToAppealFiling_AtEvaluationEnd() public {
        h.h_setCounts(1, 0, 0);

        vm.warp(h.evaluationEnd() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Evaluation));

        vm.warp(h.evaluationEnd());
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealFiling));

        vm.warp(h.evaluationEnd() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealFiling));
    }

    // ------------------------------------------------------------------ AppealFiling -> AppealResolution

    function test_Phase_AppealFilingToAppealResolution_AtAppealFilingEnd() public {
        h.h_setCounts(1, 0, 0);

        vm.warp(h.appealFilingEnd() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealFiling));

        vm.warp(h.appealFilingEnd());
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealResolution));

        vm.warp(h.appealFilingEnd() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealResolution));
    }

    // ------------------------------------------------------------------ AppealResolution -> {Failed, Cancelled, PriceReveal}

    function test_Phase_AppealResolutionToFailed_WhenUnresolvedAtPriceRevealStart() public {
        h.h_setCounts(1, 1, 0);

        vm.warp(h.priceRevealStart() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealResolution));

        vm.warp(h.priceRevealStart());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Failed));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.UnresolvedAtPriceReveal));

        vm.warp(h.priceRevealStart() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Failed));
    }

    function test_Phase_AppealResolutionToCancelled_WhenNoEligibleAtPriceRevealStart() public {
        h.h_setCounts(1, 0, 0);

        vm.warp(h.priceRevealStart() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealResolution));

        vm.warp(h.priceRevealStart());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoEligibleBids));

        vm.warp(h.priceRevealStart() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
    }

    function test_Phase_AppealResolutionToPriceReveal_WhenEligibleAtPriceRevealStart() public {
        h.h_setCounts(1, 0, 1);

        vm.warp(h.priceRevealStart() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.AppealResolution));

        vm.warp(h.priceRevealStart());
        assertEq(uint256(h.currentPhase()), uint256(Phase.PriceReveal));

        vm.warp(h.priceRevealStart() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.PriceReveal));
    }

    // ------------------------------------------------------------------ PriceReveal -> {Cancelled, Acceptance}

    function test_Phase_PriceRevealToCancelled_WhenNoRankedAtPriceRevealEnd() public {
        h.h_setCounts(1, 0, 1); // eligibleCount = 1, but no bid recorded as ranked

        vm.warp(h.priceRevealEnd() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.PriceReveal));

        vm.warp(h.priceRevealEnd());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoRankedBids));

        vm.warp(h.priceRevealEnd() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
    }

    function test_Phase_PriceRevealToAcceptance_WhenRankedAtPriceRevealEnd() public {
        address bidder = makeAddr("bidder1");
        uint64 vendorId = _registerVendor(bidder, keccak256("vendor1"));
        h.h_addBid(bidder, vendorId, BidState.Eligible, true);
        h.h_setCounts(1, 0, 1);
        assertEq(h.rankedCount(), 1);

        vm.warp(h.priceRevealEnd() - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.PriceReveal));

        vm.warp(h.priceRevealEnd());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Acceptance));

        vm.warp(h.priceRevealEnd() + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Acceptance));
    }

    // ------------------------------------------------------------------ Acceptance -> Cancelled (AllOffersLapsed)

    function test_Phase_AcceptanceToCancelled_AfterOfferWindowLapses() public {
        address bidder = makeAddr("bidder1");
        uint64 vendorId = _registerVendor(bidder, keccak256("vendor1"));
        h.h_addBid(bidder, vendorId, BidState.Eligible, true);
        h.h_setCounts(1, 0, 1);

        uint64 lapseAt = h.priceRevealEnd() + h.acceptanceWindow();

        vm.warp(lapseAt - 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Acceptance));

        vm.warp(lapseAt);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.AllOffersLapsed));

        vm.warp(lapseAt + 1);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
    }

    // ------------------------------------------------------------------ Final / Cancelled priority

    function test_Phase_Final_WhenAccepted() public {
        h.h_setAccepted(true);
        vm.warp(T0); // even long before any deadline
        assertEq(uint256(h.currentPhase()), uint256(Phase.Final));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.AwardAccepted));
    }

    function test_Phase_CancelledByPE_TakesPriorityOverAccepted() public {
        h.h_setAccepted(true);
        h.h_setCancelledByPE(true);
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.CancelledByPE));
    }

    // ------------------------------------------------------------------ rankedCount (SPEC §5)

    function test_RankedCount_IgnoresNonEligibleStates() public {
        address committed = makeAddr("committed");
        address withdrawn = makeAddr("withdrawn");
        address revealed = makeAddr("revealed");
        address ineligible = makeAddr("ineligible");
        address appealed = makeAddr("appealed");
        address eligibleNotOpened = makeAddr("eligibleNotOpened");
        address eligibleOpened = makeAddr("eligibleOpened");

        h.h_addBid(committed, _registerVendor(committed, keccak256("c")), BidState.Committed, false);
        h.h_addBid(withdrawn, _registerVendor(withdrawn, keccak256("w")), BidState.Withdrawn, false);
        h.h_addBid(revealed, _registerVendor(revealed, keccak256("r")), BidState.Revealed, false);
        h.h_addBid(
            ineligible, _registerVendor(ineligible, keccak256("i")), BidState.Ineligible, false
        );
        h.h_addBid(appealed, _registerVendor(appealed, keccak256("a")), BidState.Appealed, false);
        h.h_addBid(
            eligibleNotOpened,
            _registerVendor(eligibleNotOpened, keccak256("eno")),
            BidState.Eligible,
            false
        );
        h.h_addBid(
            eligibleOpened,
            _registerVendor(eligibleOpened, keccak256("eo")),
            BidState.Eligible,
            true
        );

        assertEq(h.rankedCount(), 1);
    }

    function test_RankedCount_ExcludesVendorDebarredBeforeCutoff() public {
        address bidder = makeAddr("debarredEarly");
        uint64 vendorId = _registerVendor(bidder, keccak256("debarredEarly"));
        h.h_addBid(bidder, vendorId, BidState.Eligible, true);
        assertEq(h.rankedCount(), 1);

        vm.warp(h.priceRevealStart() - 100);
        vm.prank(registrar);
        registry.debarVendor(vendorId, keccak256("reason"));

        assertEq(h.rankedCount(), 0);
    }

    function test_RankedCount_IncludesVendorDebarredExactlyAtCutoff() public {
        address bidder = makeAddr("debarredAtCutoff");
        uint64 vendorId = _registerVendor(bidder, keccak256("debarredAtCutoff"));
        h.h_addBid(bidder, vendorId, BidState.Eligible, true);

        vm.warp(h.priceRevealStart());
        vm.prank(registrar);
        registry.debarVendor(vendorId, keccak256("reason"));

        assertEq(h.rankedCount(), 1); // debarredAt == priceRevealStart is NOT strictly before
    }

    // ------------------------------------------------------------------ fuzz: I6, I10

    function testFuzz_PhaseOrdinalNonDecreasingOverTime(
        bool hasActiveBid,
        bool hasUnresolved,
        bool hasEligible,
        uint40 t1Offset,
        uint40 t2Offset
    ) public {
        h.h_setCounts(hasActiveBid ? 1 : 0, hasUnresolved ? 1 : 0, hasEligible ? 1 : 0);

        uint256 t1 = uint256(T0) + bound(t1Offset, 0, 20 days);
        uint256 t2 = t1 + bound(t2Offset, 0, 20 days);

        vm.warp(t1);
        uint256 ordinal1 = uint256(h.currentPhase());

        vm.warp(t2);
        uint256 ordinal2 = uint256(h.currentPhase());

        assertGe(ordinal2, ordinal1);
    }

    function testFuzz_TerminalPhaseIsAbsorbing(
        bool hasActiveBid,
        bool hasUnresolved,
        bool hasEligible,
        uint40 t1Offset,
        uint40 t2Offset
    ) public {
        h.h_setCounts(hasActiveBid ? 1 : 0, hasUnresolved ? 1 : 0, hasEligible ? 1 : 0);

        uint256 t1 = uint256(T0) + bound(t1Offset, 0, 20 days);
        uint256 t2 = t1 + bound(t2Offset, 0, 20 days);

        vm.warp(t1);
        bool wasTerminal = _isTerminal(h.currentPhase());

        vm.warp(t2);
        bool isTerminal = _isTerminal(h.currentPhase());

        if (wasTerminal) assertTrue(isTerminal);
    }

    function testFuzz_CancelledByPEIsAbsorbing(uint40 t1Offset, uint40 t2Offset) public {
        h.h_setCancelledByPE(true);

        vm.warp(uint256(T0) + bound(t1Offset, 0, 30 days));
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));

        vm.warp(uint256(T0) + bound(t2Offset, 0, 30 days));
        assertEq(uint256(h.currentPhase()), uint256(Phase.Cancelled));
    }

    function testFuzz_AcceptedIsAbsorbingUnlessCancelled(uint40 t1Offset, uint40 t2Offset) public {
        h.h_setAccepted(true);

        vm.warp(uint256(T0) + bound(t1Offset, 0, 30 days));
        assertEq(uint256(h.currentPhase()), uint256(Phase.Final));

        vm.warp(uint256(T0) + bound(t2Offset, 0, 30 days));
        assertEq(uint256(h.currentPhase()), uint256(Phase.Final));
    }
}
