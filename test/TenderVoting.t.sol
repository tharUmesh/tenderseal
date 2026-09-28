// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {Bid, BidState, Phase} from "../src/TenderTypes.sol";
import {TenderHarness} from "./harness/TenderHarness.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `postKeyEnvelope` / `declareConflict` / `castVote` tests (SPEC §6.4-6.5, §8).
contract TenderVotingTest is TenderTestBase {
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");

    bytes32 internal constant PRICE_COMMIT = keccak256("p");
    bytes32 internal constant DOC_HASH = keccak256("d");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");
    bytes32 internal constant KEY_ENV_REF = keccak256("k");
    bytes32 internal constant REPORT_HASH = keccak256("r");

    // Mirrors Tender's public constants (SPEC §8). Using these locally, rather than
    // calling tender.REASON_X() inline as a call argument, avoids a Foundry footgun:
    // an inline external call evaluated as an argument counts as "the next call" and
    // silently consumes a pending vm.prank/vm.expectRevert meant for the outer call.
    uint8 internal constant REASON_COMPLIANT = 1;
    uint8 internal constant REASON_SPEC_NONCOMPLIANT = 2;
    uint8 internal constant REASON_OTHER_DOCUMENTED = 8;

    event KeyEnvelopePosted(address indexed bidder, bytes32 keyEnvelopeRef);
    event ConflictDeclared(address indexed evaluator, bytes32 declarationHash);
    event VoteCast(
        address indexed evaluator,
        address indexed bidder,
        bool eligible,
        uint8 reasonCode,
        bytes32 reportHash
    );
    event VerdictFinalized(address indexed bidder, bool eligible);

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

    function _commitAndReveal(address bidder) internal {
        _commit(bidder);
        vm.warp(tender.submissionDeadline());
        _reveal(bidder);
    }

    // ==================================================================
    // postKeyEnvelope (SPEC §6.4)
    // ==================================================================

    function test_PostKeyEnvelope_TransitionsCommittedToRevealed() public {
        _commit(bidder1);
        vm.warp(tender.submissionDeadline());

        vm.expectEmit(true, false, false, true);
        emit KeyEnvelopePosted(bidder1, KEY_ENV_REF);
        _reveal(bidder1);

        Bid memory bid = tender.getBid(bidder1);
        assertEq(uint256(bid.state), uint256(BidState.Revealed));
        assertEq(bid.keyEnvelopeRef, KEY_ENV_REF);
    }

    function test_PostKeyEnvelope_RevertsWhenNoBid() public {
        _commit(bidder2); // keeps _activeBidCount > 0 so the tender reaches TechReveal
        vm.warp(tender.submissionDeadline());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.None));
        vm.prank(bidder1);
        tender.postKeyEnvelope(KEY_ENV_REF);
    }

    function test_PostKeyEnvelope_RevertsWhenAlreadyRevealed() public {
        _commitAndReveal(bidder1);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Revealed));
        _reveal(bidder1);
    }

    function test_PostKeyEnvelope_RevertsOnZeroRef() public {
        _commit(bidder1);
        vm.warp(tender.submissionDeadline());
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(bidder1);
        tender.postKeyEnvelope(bytes32(0));
    }

    function test_PostKeyEnvelope_RevertsBeforeSubmissionDeadline() public {
        _commit(bidder1);
        vm.warp(tender.submissionDeadline() - 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Open));
        _reveal(bidder1);
    }

    function test_PostKeyEnvelope_RevertsAtTechRevealEnd_BidBecomesForfeitedF1() public {
        // At techRevealEnd, a still-Committed bid is exactly the derived "ForfeitedF1"
        // status (SPEC §4): postKeyEnvelope is no longer reachable for it.
        _commit(bidder1);
        vm.warp(tender.techRevealEnd() - 1);
        assertEq(uint256(tender.currentPhase()), uint256(Phase.TechReveal));

        vm.warp(tender.techRevealEnd());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Evaluation));
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Evaluation));
        _reveal(bidder1);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Committed));
    }

    // ==================================================================
    // declareConflict (SPEC §6.5)
    // ==================================================================

    function test_DeclareConflict_EmitsEventWithNoStateEffect() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());

        vm.expectEmit(true, false, false, true);
        emit ConflictDeclared(eval1, keccak256("conflict"));
        vm.prank(eval1);
        tender.declareConflict(keccak256("conflict"));

        // No effect: the evaluator can still vote normally afterward.
        assertFalse(tender.hasVoted(bidder1, eval1));
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        assertTrue(tender.hasVoted(bidder1, eval1));
    }

    function test_DeclareConflict_RevertsWhenNotEvaluator() public {
        vm.expectRevert(Tender.NotEvaluator.selector);
        vm.prank(bidder1);
        tender.declareConflict(keccak256("conflict"));
    }

    function test_DeclareConflict_AllowedDuringOpenPhase() public {
        // The gate is a raw time check (now < evaluationEnd), not tied to a specific phase.
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Open));
        vm.prank(eval1);
        tender.declareConflict(keccak256("conflict"));
    }

    function test_DeclareConflict_AllowedJustBeforeEvaluationEnd() public {
        _commit(bidder1); // keeps _activeBidCount > 0 so the tender reaches Evaluation
        vm.warp(tender.evaluationEnd() - 1);
        vm.prank(eval1);
        tender.declareConflict(keccak256("conflict"));
    }

    function test_DeclareConflict_RevertsAtEvaluationEnd() public {
        _commit(bidder1); // keeps _activeBidCount > 0 so the tender reaches AppealFiling
        vm.warp(tender.evaluationEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.AppealFiling));
        vm.prank(eval1);
        tender.declareConflict(keccak256("conflict"));
    }

    // ==================================================================
    // castVote (SPEC §6.5, §8)
    // ==================================================================

    function test_CastVote_RevertsWhenNotEvaluator() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(Tender.NotEvaluator.selector);
        vm.prank(bidder2);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
    }

    function test_CastVote_RevertsWhenBidNotRevealed() public {
        _commit(bidder1); // still Committed, never revealed
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Committed));
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
    }

    function test_CastVote_RevertsOnZeroReportHash() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, bytes32(0));
    }

    function test_CastVote_RevertsOnReasonCodeTwo_WhenEligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(
            abi.encodeWithSelector(Tender.InvalidReasonCode.selector, REASON_SPEC_NONCOMPLIANT)
        );
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
    }

    function test_CastVote_RevertsOnReasonCodeZero_WhenIneligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidReasonCode.selector, 0));
        vm.prank(eval1);
        tender.castVote(bidder1, false, 0, REPORT_HASH);
    }

    function test_CastVote_RevertsOnReasonCodeOne_WhenIneligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidReasonCode.selector, REASON_COMPLIANT));
        vm.prank(eval1);
        tender.castVote(bidder1, false, REASON_COMPLIANT, REPORT_HASH);
    }

    function test_CastVote_RevertsOnReasonCodeNine_WhenIneligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidReasonCode.selector, 9));
        vm.prank(eval1);
        tender.castVote(bidder1, false, 9, REPORT_HASH);
    }

    function test_CastVote_AcceptsReasonCodeOne_WhenEligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        assertTrue(tender.hasVoted(bidder1, eval1));
    }

    function test_CastVote_AcceptsReasonCodeTwo_WhenIneligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        assertTrue(tender.hasVoted(bidder1, eval1));
    }

    function test_CastVote_AcceptsReasonCodeEight_WhenIneligible() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, false, REASON_OTHER_DOCUMENTED, REPORT_HASH);
        assertTrue(tender.hasVoted(bidder1, eval1));
    }

    function test_CastVote_RevertsOnAlreadyVoted() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);

        vm.expectRevert(Tender.AlreadyVoted.selector);
        vm.prank(eval1);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
    }

    function test_CastVote_FinalizesEligibleAtThreshold() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());

        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Revealed));

        vm.expectEmit(true, false, false, true);
        emit VerdictFinalized(bidder1, true);
        vm.prank(eval2);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Eligible));
    }

    function test_CastVote_FinalizesIneligibleAtThreshold() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());

        vm.prank(eval1);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);

        vm.expectEmit(true, false, false, true);
        emit VerdictFinalized(bidder1, false);
        vm.prank(eval2);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Ineligible));
    }

    function test_CastVote_RevertsWhenVerdictAlreadyFinalized() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);

        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Eligible));
        vm.prank(eval3);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
    }

    function test_CastVote_SplitVotes_RemainsRevealedThenEscalated() public {
        // Abstention: eval3 never votes. 1 eligible + 1 ineligible can never reach k=2
        // on either side (I3), so the bid stays Revealed past evaluationEnd -> Escalated.
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd());

        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Revealed));

        vm.warp(tender.evaluationEnd());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.AppealFiling));
        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Revealed)); // Escalated
    }

    function test_CastVote_RevertsBeforeTechRevealEnd() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.techRevealEnd() - 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.TechReveal));
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
    }

    function test_CastVote_RevertsAtEvaluationEnd() public {
        _commitAndReveal(bidder1);
        vm.warp(tender.evaluationEnd());
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.AppealFiling));
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
    }

    // ==================================================================
    // Cancellation must win even when the raw time is still within the
    // function's normal window (the gate must consult _evaluate(), not
    // raw timestamps).
    // ==================================================================

    function test_PostKeyEnvelope_RevertsWhenCancelledByPE_WithinWindow() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.warp(h.submissionDeadline()); // TechReveal window
        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        h.postKeyEnvelope(KEY_ENV_REF);
    }

    function test_DeclareConflict_RevertsWhenCancelledByPE_WithinWindow() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.warp(h.techRevealEnd()); // Evaluation window; now < evaluationEnd still holds
        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(eval1);
        h.declareConflict(keccak256("conflict"));
    }

    function test_CastVote_RevertsWhenCancelledByPE_WithinWindow() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.warp(h.submissionDeadline());
        vm.prank(bidder1);
        h.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(h.techRevealEnd()); // Evaluation window
        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(eval1);
        h.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
    }
}
