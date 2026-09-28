// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {BidState, Phase, TerminalCause} from "../src/TenderTypes.sol";
import {TenderHarness} from "./harness/TenderHarness.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `fileAppeal` / `resolveEscalation` / `resolveAppeal` tests (SPEC §6.6).
contract TenderAppealsTest is TenderTestBase {
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");

    bytes32 internal constant PRICE_COMMIT = keccak256("p");
    bytes32 internal constant DOC_HASH = keccak256("d");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");
    bytes32 internal constant KEY_ENV_REF = keccak256("k");
    bytes32 internal constant REPORT_HASH = keccak256("r");
    bytes32 internal constant COMPLAINT_HASH = keccak256("complaint");
    bytes32 internal constant REASON_HASH = keccak256("reason");

    uint8 internal constant REASON_SPEC_NONCOMPLIANT = 2;

    event AppealFiled(address indexed bidder, bytes32 complaintHash);
    event EscalationResolved(address indexed bidder, bool eligible, bytes32 reasonHash);
    event AppealResolved(address indexed bidder, bool upheld, bytes32 reasonHash);

    function setUp() public override {
        super.setUp();

        _registerVendor(bidder1, keccak256("bidder1"));
        _registerVendor(bidder2, keccak256("bidder2"));

        vm.warp(T0 + 1 hours);
        tender = new Tender(_defaultConfig());

        _fundAndApprove(bidder1);
        _fundAndApprove(bidder2);
    }

    function _fundAndApprove(address who) internal {
        vm.prank(admin);
        token.mint(who, DEPOSIT * 10);
        vm.prank(who);
        token.approve(address(tender), type(uint256).max);
    }

    function _fundAndApprove(Tender t, address who) internal {
        vm.prank(admin);
        token.mint(who, DEPOSIT * 10);
        vm.prank(who);
        token.approve(address(t), type(uint256).max);
    }

    function _commit(address bidder) internal {
        vm.prank(bidder);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function _reveal(address bidder) internal {
        vm.prank(bidder);
        tender.postKeyEnvelope(KEY_ENV_REF);
    }

    /// @dev Commits, reveals, and votes `bidder` to a final Ineligible verdict (2 of 3).
    function _makeIneligible(address bidder) internal {
        _commit(bidder);
        vm.warp(tender.submissionDeadline());
        _reveal(bidder);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
    }

    /// @dev Files an appeal for an already-Ineligible bidder, at the start of AppealFiling.
    function _appeal(address bidder) internal {
        vm.warp(tender.evaluationEnd());
        vm.prank(bidder);
        tender.fileAppeal(COMPLAINT_HASH);
    }

    /// @dev Commits and reveals `bidder`, but leaves it Revealed past evaluationEnd
    ///      (no vote reaches threshold) -> Escalated (derived, SPEC §4).
    function _makeEscalated(address bidder) internal {
        _commit(bidder);
        vm.warp(tender.submissionDeadline());
        _reveal(bidder);
        vm.warp(tender.evaluationEnd());
    }

    // ==================================================================
    // fileAppeal (SPEC §6.6)
    // ==================================================================

    function test_FileAppeal_TransitionsIneligibleToAppealed() public {
        _makeIneligible(bidder1);
        vm.warp(tender.evaluationEnd());

        vm.expectEmit(true, false, false, true);
        emit AppealFiled(bidder1, COMPLAINT_HASH);
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Appealed));
    }

    function test_FileAppeal_RevertsWhenNotIneligible() public {
        _commit(bidder1);
        vm.warp(tender.submissionDeadline());
        _reveal(bidder1); // Revealed, never voted -> not Ineligible
        vm.warp(tender.evaluationEnd());

        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Revealed));
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);
    }

    function test_FileAppeal_RevertsOnZeroComplaintHash() public {
        _makeIneligible(bidder1);
        vm.warp(tender.evaluationEnd());
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(bidder1);
        tender.fileAppeal(bytes32(0));
    }

    function test_FileAppeal_RevertsWhenAlreadyAppealedAndDismissed() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);

        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, false, REASON_HASH); // dismissed -> back to Ineligible

        vm.expectRevert(Tender.AppealNotAllowed.selector);
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);
    }

    function test_FileAppeal_RevertsWhenResolvedByAuthority() public {
        _makeEscalated(bidder1);
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, false, REASON_HASH); // -> Ineligible, not appealable

        vm.expectRevert(Tender.AppealNotAllowed.selector);
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);
    }

    function test_FileAppeal_RevertsBeforeAppealFilingPhase() public {
        _makeIneligible(bidder1);
        // Still at techRevealEnd time (Evaluation), not yet AppealFiling.
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Evaluation));
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);
    }

    function test_FileAppeal_RevertsAfterAppealFilingEnd() public {
        _makeIneligible(bidder1);
        vm.warp(tender.appealFilingEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.AppealResolution));
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);
    }

    function test_FileAppeal_AllowedJustBeforeAppealFilingEnd() public {
        _makeIneligible(bidder1);
        vm.warp(tender.appealFilingEnd() - 1);
        vm.prank(bidder1);
        tender.fileAppeal(COMPLAINT_HASH);
        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Appealed));
    }

    // ==================================================================
    // resolveEscalation (SPEC §6.6)
    // ==================================================================

    function test_ResolveEscalation_EligibleTrue() public {
        _makeEscalated(bidder1);

        vm.expectEmit(true, false, false, true);
        emit EscalationResolved(bidder1, true, REASON_HASH);
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, REASON_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Eligible));
        assertTrue(tender.getBid(bidder1).resolvedByAuthority);
    }

    function test_ResolveEscalation_EligibleFalse() public {
        _makeEscalated(bidder1);

        vm.expectEmit(true, false, false, true);
        emit EscalationResolved(bidder1, false, REASON_HASH);
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, false, REASON_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Ineligible));
        assertTrue(tender.getBid(bidder1).resolvedByAuthority);
    }

    function test_ResolveEscalation_RevertsWhenNotAuthority() public {
        _makeEscalated(bidder1);
        vm.expectRevert(Tender.NotAuthority.selector);
        vm.prank(pe);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
    }

    function test_ResolveEscalation_RevertsWhenCalledByEvaluator() public {
        _makeEscalated(bidder1);
        vm.expectRevert(Tender.NotAuthority.selector);
        vm.prank(eval1);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
    }

    function test_ResolveEscalation_RevertsWhenBidNotRevealed() public {
        _commit(bidder1); // still Committed
        vm.warp(tender.evaluationEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Committed));
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
    }

    function test_ResolveEscalation_RevertsOnZeroReasonHash() public {
        _makeEscalated(bidder1);
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, bytes32(0));
    }

    function test_ResolveEscalation_RevertsBeforeEvaluationEnd() public {
        _commit(bidder1);
        vm.warp(tender.submissionDeadline());
        _reveal(bidder1);
        // Still within Evaluation, one second before evaluationEnd.
        vm.warp(tender.evaluationEnd() - 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Evaluation));
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
    }

    function test_ResolveEscalation_AllowedJustBeforePriceRevealStart() public {
        _makeEscalated(bidder1);
        vm.warp(tender.priceRevealStart() - 1);
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Eligible));
    }

    function test_ResolveEscalation_RevertsAtPriceRevealStart() public {
        _makeEscalated(bidder1);
        vm.warp(tender.priceRevealStart());
        // Still unresolved at priceRevealStart -> Failed (also SPEC §4's own rule).
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Failed));
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
    }

    function test_ResolveEscalation_CannotTouchFinalizedEligibleVerdict() public {
        _commit(bidder1);
        vm.warp(tender.submissionDeadline());
        _reveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, true, 1, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder1, true, 1, REPORT_HASH); // finalized Eligible by majority

        vm.warp(tender.evaluationEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Eligible));
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, false, REASON_HASH);
    }

    function test_ResolveEscalation_CannotTouchFinalizedIneligibleVerdictWithoutAppeal() public {
        _makeIneligible(bidder1);
        vm.warp(tender.evaluationEnd());
        vm.expectRevert(
            abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Ineligible)
        );
        vm.prank(appealsAuthority);
        tender.resolveEscalation(bidder1, true, REASON_HASH);
    }

    // ==================================================================
    // resolveAppeal (SPEC §6.6)
    // ==================================================================

    function test_ResolveAppeal_Upheld() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);

        vm.expectEmit(true, false, false, true);
        emit AppealResolved(bidder1, true, REASON_HASH);
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, true, REASON_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Eligible));
    }

    function test_ResolveAppeal_Dismissed() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);

        vm.expectEmit(true, false, false, true);
        emit AppealResolved(bidder1, false, REASON_HASH);
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, false, REASON_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Ineligible));
    }

    function test_ResolveAppeal_RevertsWhenNotAuthority() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);
        vm.expectRevert(Tender.NotAuthority.selector);
        vm.prank(pe);
        tender.resolveAppeal(bidder1, true, REASON_HASH);
    }

    function test_ResolveAppeal_RevertsWhenBidNotAppealed() public {
        _makeIneligible(bidder1); // Ineligible, but never appealed
        vm.warp(tender.evaluationEnd());
        vm.expectRevert(
            abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Ineligible)
        );
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, true, REASON_HASH);
    }

    function test_ResolveAppeal_RevertsOnZeroReasonHash() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, true, bytes32(0));
    }

    function test_ResolveAppeal_RevertsBeforeEvaluationEnd() public {
        // The window check runs before the bid-state check, so this boundary is visible
        // even on a bidder that (being before AppealFiling) can't yet be Appealed.
        _makeIneligible(bidder1);
        vm.warp(tender.evaluationEnd() - 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Evaluation));
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, true, REASON_HASH);
    }

    function test_ResolveAppeal_RevertsAtPriceRevealStart() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);
        vm.warp(tender.priceRevealStart());
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Failed));
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, true, REASON_HASH);
    }

    function test_ResolveAppeal_AllowedJustBeforePriceRevealStart() public {
        _makeIneligible(bidder1);
        _appeal(bidder1);
        vm.warp(tender.priceRevealStart() - 1);
        vm.prank(appealsAuthority);
        tender.resolveAppeal(bidder1, true, REASON_HASH);
        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Eligible));
    }

    // ==================================================================
    // Integration: unresolved at priceRevealStart -> Failed (SPEC §4, §6.6)
    // ==================================================================

    function test_UnresolvedEscalatedBidAtPriceRevealStart_CausesFailed() public {
        _makeEscalated(bidder1); // never resolved by authority
        vm.warp(tender.priceRevealStart());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Failed));
        assertEq(uint256(tender.terminalCause()), uint256(TerminalCause.UnresolvedAtPriceReveal));
    }

    function test_UnresolvedAppealedBidAtPriceRevealStart_CausesFailed() public {
        _makeIneligible(bidder1);
        _appeal(bidder1); // never resolved by authority
        vm.warp(tender.priceRevealStart());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Failed));
        assertEq(uint256(tender.terminalCause()), uint256(TerminalCause.UnresolvedAtPriceReveal));
    }

    // ==================================================================
    // Cancellation must win even when the raw time is still within the
    // authority window (the gate must consult _evaluate(), not raw timestamps).
    // ==================================================================

    function test_FileAppeal_RevertsWhenCancelledByPE_WithinWindow() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.warp(h.submissionDeadline());
        vm.prank(bidder1);
        h.postKeyEnvelope(KEY_ENV_REF);
        vm.warp(h.techRevealEnd());
        vm.prank(eval1);
        h.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        h.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH); // -> Ineligible

        vm.warp(h.evaluationEnd()); // AppealFiling window
        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        h.fileAppeal(COMPLAINT_HASH);
    }

    function test_ResolveEscalation_RevertsWhenCancelledByPE_WithinWindow() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.warp(h.submissionDeadline());
        vm.prank(bidder1);
        h.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(h.evaluationEnd()); // still Revealed -> Escalated; AppealFiling window
        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(appealsAuthority);
        h.resolveEscalation(bidder1, true, REASON_HASH);
    }

    function test_ResolveAppeal_RevertsWhenCancelledByPE_WithinWindow() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.warp(h.submissionDeadline());
        vm.prank(bidder1);
        h.postKeyEnvelope(KEY_ENV_REF);
        vm.warp(h.techRevealEnd());
        vm.prank(eval1);
        h.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        h.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.warp(h.evaluationEnd());
        vm.prank(bidder1);
        h.fileAppeal(COMPLAINT_HASH); // -> Appealed, still within AppealFiling

        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(appealsAuthority);
        h.resolveAppeal(bidder1, true, REASON_HASH);
    }
}
