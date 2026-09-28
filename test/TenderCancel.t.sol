// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {BidState, Phase, Settlement} from "../src/TenderTypes.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `cancel` tests (SPEC §6.7): the phase x reason-code matrix, and the F1 interaction.
contract TenderCancelTest is TenderTestBase {
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1");

    bytes32 internal constant DOC_HASH = keccak256("d");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");
    bytes32 internal constant KEY_ENV_REF = keccak256("k");
    bytes32 internal constant REPORT_HASH = keccak256("r");
    bytes32 internal constant SALT = keccak256("salt1");
    bytes32 internal constant CANCEL_REASON = keccak256("cancel-reason");
    uint256 internal constant PRICE = 12_345;

    uint8 internal constant REASON_COMPLIANT = 1;

    event TenderCancelled(uint8 reasonCode, bytes32 reasonHash);

    function setUp() public override {
        super.setUp();
        _registerVendor(bidder1, keccak256("bidder1"));
        vm.warp(T0 + 1 hours);
        tender = new Tender(_defaultConfig());
        _fundAndApprove(tender, bidder1);
    }

    function _fundAndApprove(Tender t, address who) internal {
        vm.prank(admin);
        token.mint(who, DEPOSIT * 10);
        vm.prank(who);
        token.approve(address(t), type(uint256).max);
    }

    function _commitment(Tender t, address bidder) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(t), bidder, PRICE, DOC_HASH, SALT));
    }

    function _commit(Tender t, address bidder) internal {
        vm.prank(bidder);
        t.commit(_commitment(t, bidder), DOC_HASH, DOC_CIPHER_REF);
    }

    function _reveal(Tender t, address bidder) internal {
        vm.prank(bidder);
        t.postKeyEnvelope(KEY_ENV_REF);
    }

    /// @dev Commits, reveals, and votes `bidder` to Eligible (2 of 3), using a fresh
    ///      commitment computed against `t`.
    function _makeEligible(Tender t, address bidder) internal {
        _commit(t, bidder);
        vm.warp(t.submissionDeadline());
        _reveal(t, bidder);
        vm.warp(t.techRevealEnd());
        vm.prank(eval1);
        t.castVote(bidder, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        t.castVote(bidder, true, REASON_COMPLIANT, REPORT_HASH);
    }

    // ==================================================================
    // Caller / hash checks
    // ==================================================================

    function test_Cancel_RevertsWhenNotPE() public {
        vm.expectRevert(Tender.NotPE.selector);
        vm.prank(bidder1);
        tender.cancel(1, CANCEL_REASON);
    }

    function test_Cancel_RevertsOnZeroReasonHash() public {
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(pe);
        tender.cancel(1, bytes32(0));
    }

    function test_Cancel_EmitsEventAndSetsCancelledState() public {
        vm.expectEmit(false, false, false, true);
        emit TenderCancelled(2, CANCEL_REASON);
        vm.prank(pe);
        tender.cancel(2, CANCEL_REASON);

        assertEq(uint256(tender.currentPhase()), uint256(Phase.Cancelled));
    }

    // ==================================================================
    // Open: codes 1-4 all allowed
    // ==================================================================

    function test_Cancel_Open_AcceptsAllCodes() public {
        for (uint8 code = 1; code <= 4; code++) {
            Tender t = new Tender(_defaultConfig());
            vm.prank(pe);
            t.cancel(code, CANCEL_REASON);
            assertEq(uint256(t.currentPhase()), uint256(Phase.Cancelled));
        }
    }

    function test_Cancel_Open_RevertsOnCodeZero() public {
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidReasonCode.selector, 0));
        vm.prank(pe);
        tender.cancel(0, CANCEL_REASON);
    }

    function test_Cancel_Open_RevertsOnCodeFive() public {
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidReasonCode.selector, 5));
        vm.prank(pe);
        tender.cancel(5, CANCEL_REASON);
    }

    // ==================================================================
    // Sealed phases (TechReveal, Evaluation, AppealFiling, AppealResolution):
    // codes 1-3 allowed, code 4 rejected
    // ==================================================================

    function test_Cancel_SealedPhases_AcceptCodes1To3() public {
        for (uint256 p = 0; p < 4; p++) {
            for (uint8 code = 1; code <= 3; code++) {
                // Reset before each deployment: _defaultConfig()'s schedule is fixed
                // relative to T0, earlier iterations warped time forward, and createdAt
                // must stay strictly after bidder1's registration at T0.
                vm.warp(T0 + 1 hours);
                Tender t = new Tender(_defaultConfig());
                _fundAndApprove(t, bidder1);
                _commit(t, bidder1); // keeps _activeBidCount > 0

                if (p == 0) vm.warp(t.submissionDeadline());
                else if (p == 1) vm.warp(t.techRevealEnd());
                else if (p == 2) vm.warp(t.evaluationEnd());
                else vm.warp(t.appealFilingEnd());

                vm.prank(pe);
                t.cancel(code, CANCEL_REASON);
                assertEq(uint256(t.currentPhase()), uint256(Phase.Cancelled));
            }
        }
    }

    function test_Cancel_SealedPhases_RevertOnCodeFour() public {
        Phase[4] memory expectedPhase =
            [Phase.TechReveal, Phase.Evaluation, Phase.AppealFiling, Phase.AppealResolution];
        for (uint256 p = 0; p < 4; p++) {
            vm.warp(T0 + 1 hours); // reset before each deployment (see AcceptCodes1To3)
            Tender t = new Tender(_defaultConfig());
            _fundAndApprove(t, bidder1);
            _commit(t, bidder1);

            if (p == 0) vm.warp(t.submissionDeadline());
            else if (p == 1) vm.warp(t.techRevealEnd());
            else if (p == 2) vm.warp(t.evaluationEnd());
            else vm.warp(t.appealFilingEnd());

            assertEq(uint256(t.currentPhase()), uint256(expectedPhase[p]));
            vm.expectRevert(abi.encodeWithSelector(Tender.InvalidReasonCode.selector, 4));
            vm.prank(pe);
            t.cancel(4, CANCEL_REASON);
        }
    }

    // ==================================================================
    // Disallowed phases: WrongPhase regardless of code
    // ==================================================================

    function test_Cancel_RevertsInPriceReveal() public {
        _makeEligible(tender, bidder1);
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.PriceReveal));
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);
    }

    function test_Cancel_RevertsInAcceptance() public {
        _makeEligible(tender, bidder1);
        vm.warp(tender.priceRevealStart());
        tender.revealPrice(bidder1, PRICE, SALT);
        vm.warp(tender.priceRevealEnd());

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Acceptance));
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);
    }

    function test_Cancel_RevertsInFinal() public {
        _makeEligible(tender, bidder1);
        vm.warp(tender.priceRevealStart());
        tender.revealPrice(bidder1, PRICE, SALT);
        vm.warp(tender.priceRevealEnd());
        vm.prank(bidder1);
        tender.acceptAward();

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Final));
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);
    }

    function test_Cancel_RevertsWhenAlreadyCancelled() public {
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);
    }

    function test_Cancel_RevertsInCancelledViaNoBids() public {
        Tender t = new Tender(_defaultConfig()); // no bids ever
        vm.warp(t.submissionDeadline());
        assertEq(uint256(t.currentPhase()), uint256(Phase.Cancelled));

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(pe);
        t.cancel(1, CANCEL_REASON);
    }

    function test_Cancel_RevertsInFailed() public {
        _commit(tender, bidder1);
        vm.warp(tender.submissionDeadline());
        _reveal(tender, bidder1); // Revealed, never voted -> stuck (Escalated, then unresolved)
        vm.warp(tender.priceRevealStart());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Failed));

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Failed));
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);
    }

    // ==================================================================
    // F1 interaction: PE-cancel after techRevealEnd keeps F1; before, it doesn't
    // ==================================================================

    function test_Cancel_AfterTechRevealEnd_KeepsF1() public {
        _commit(tender, bidder1); // never reveals

        vm.warp(tender.techRevealEnd() + 1);
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);

        (Settlement outcome, address recipient, uint256 amount) = tender.settlementOf(bidder1);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, tender.depositAmount());
    }

    function test_Cancel_BeforeTechRevealEnd_NoForfeit() public {
        _commit(tender, bidder1); // never reveals

        vm.warp(tender.submissionDeadline() + 1); // TechReveal, before techRevealEnd
        vm.prank(pe);
        tender.cancel(1, CANCEL_REASON);

        (Settlement outcome, address recipient, uint256 amount) = tender.settlementOf(bidder1);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder1);
        assertEq(amount, tender.depositAmount());
    }
}
