// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {BidState, Phase, Settlement, TerminalCause} from "../src/TenderTypes.sol";
import {TenderHarness} from "./harness/TenderHarness.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `settlementOf` / `settle` tests: every rule in SPEC §7, settle-once (I11), and
///      direct-transfer accounting (I1).
contract TenderSettleTest is TenderTestBase {
    TenderHarness internal h;

    address internal realBidder;
    uint64 internal realVendorId;

    event DepositSettled(
        address indexed bidder, address indexed recipient, uint256 amount, bool forfeited
    );

    function setUp() public override {
        super.setUp(); // warps to T0

        realBidder = makeAddr("realBidder");
        realVendorId = _registerVendor(realBidder, keccak256("realBidder"));

        vm.warp(T0 + 1 hours); // createdAt strictly after registration
        h = new TenderHarness(_defaultConfig());

        vm.prank(admin);
        token.mint(realBidder, DEPOSIT * 10);
        vm.prank(realBidder);
        token.approve(address(h), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Adds a ranked (Eligible, opened) bid at `price` with a fresh vendor ID.
    function _addRanked(string memory label, uint64 vendorId, uint256 price)
        internal
        returns (address bidder)
    {
        bidder = makeAddr(label);
        h.h_addBid(bidder, vendorId, BidState.Eligible, false);
        h.h_setOpened(bidder, price);
    }

    function _warpToAllOffersLapsed(uint256 rankedCount_) internal {
        vm.warp(h.priceRevealEnd() + rankedCount_ * h.acceptanceWindow());
    }

    // ==================================================================
    // Before terminal
    // ==================================================================

    function test_SettlementOf_WithdrawnBeforeTerminal_IsRefund() public {
        address bidder = makeAddr("withdrawn");
        h.h_addBid(bidder, 1, BidState.Withdrawn, false);

        // Still well before submissionDeadline: the tender is not terminal.
        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_PendingBeforeTerminal() public {
        address bidder = makeAddr("committed");
        h.h_addBid(bidder, 1, BidState.Committed, false);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Pending));
        assertEq(recipient, address(0));
        assertEq(amount, 0);
    }

    // ==================================================================
    // F1
    // ==================================================================

    function test_SettlementOf_F1_ForfeitsCommittedGhostBidder() public {
        address bidder = makeAddr("ghost");
        h.h_addBid(bidder, 1, BidState.Committed, false);
        h.h_setCounts(1, 0, 0); // one active bid, never becomes eligible

        vm.warp(h.priceRevealStart()); // -> Cancelled / NoEligibleBids, not PE-cancelled
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoEligibleBids));

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_F1_ForfeitsWhenCancelledAfterTechRevealEnd() public {
        address bidder = makeAddr("ghost");
        h.h_addBid(bidder, 1, BidState.Committed, false);
        h.h_setCancelledAt(h.techRevealEnd() + 1);
        h.h_setCancelledByPE(true);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_Refund_CommittedCancelledBeforeTechRevealEnd() public {
        address bidder = makeAddr("ghost");
        h.h_addBid(bidder, 1, BidState.Committed, false);
        h.h_setCancelledAt(h.submissionDeadline() + 1); // before techRevealEnd
        h.h_setCancelledByPE(true);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder);
        assertEq(amount, h.depositAmount());
    }

    // ==================================================================
    // F2
    // ==================================================================

    function test_SettlementOf_F2_ForfeitsWithheldPrice_NoRankedBids() public {
        address bidder = _addRankedButHide("withheld1", 1);
        h.h_setCounts(1, 0, 1);

        vm.warp(h.priceRevealEnd()); // no bid opened -> NoRankedBids
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoRankedBids));

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_F2_ForfeitsWithheldPrice_AllOffersLapsed() public {
        address ranked = _addRanked("ranked", 1, 100);
        address hidden = _addRankedButHide("hidden", 2);
        h.h_setCounts(1, 0, 2);

        _warpToAllOffersLapsed(1); // the one ranked (opened) bid's window lapses
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.AllOffersLapsed));

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(hidden);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, h.depositAmount());
        ranked; // ranked bidder's own outcome is covered by the F3 tests below
    }

    function test_SettlementOf_F2_ForfeitsWithheldPrice_AwardAccepted() public {
        address winner = _addRanked("winner", 1, 100);
        address hidden = _addRankedButHide("hidden", 2);
        h.h_setCounts(1, 0, 2);
        h.h_setAccepted(true);
        h.h_setWinner(winner);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(hidden);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, h.depositAmount());
    }

    function _addRankedButHide(string memory label, uint64 vendorId)
        internal
        returns (address bidder)
    {
        bidder = makeAddr(label);
        h.h_addBid(bidder, vendorId, BidState.Eligible, false);
    }

    // ==================================================================
    // F3
    // ==================================================================

    function test_SettlementOf_F3_ForfeitsEveryRankedBid_WhenAllOffersLapsed() public {
        address a = _addRanked("a", 1, 100);
        address b = _addRanked("b", 2, 200);
        h.h_setCounts(1, 0, 2);

        _warpToAllOffersLapsed(2);
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.AllOffersLapsed));

        (Settlement outcomeA, address recipientA, uint256 amountA) = h.settlementOf(a);
        (Settlement outcomeB, address recipientB, uint256 amountB) = h.settlementOf(b);
        assertEq(uint256(outcomeA), uint256(Settlement.Forfeit));
        assertEq(recipientA, treasury);
        assertEq(amountA, h.depositAmount());
        assertEq(uint256(outcomeB), uint256(Settlement.Forfeit));
        assertEq(recipientB, treasury);
        assertEq(amountB, h.depositAmount());
    }

    function test_SettlementOf_F3_ForfeitsEarlierRankedBidder_WhenAwardAccepted() public {
        address earlier = _addRanked("earlier", 1, 100); // ranking index 0
        address winner = _addRanked("winner", 2, 200); // ranking index 1
        h.h_setCounts(1, 0, 2);
        h.h_setAccepted(true);
        h.h_setWinner(winner);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(earlier);
        assertEq(uint256(outcome), uint256(Settlement.Forfeit));
        assertEq(recipient, treasury);
        assertEq(amount, h.depositAmount());
    }

    // ==================================================================
    // Refund
    // ==================================================================

    function test_SettlementOf_Refund_Winner() public {
        address earlier = _addRanked("earlier", 1, 100);
        address winner = _addRanked("winner", 2, 200);
        h.h_setCounts(1, 0, 2);
        h.h_setAccepted(true);
        h.h_setWinner(winner);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(winner);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, winner);
        assertEq(amount, h.depositAmount());
        earlier;
    }

    function test_SettlementOf_Refund_RankedBidderAfterWinner() public {
        address winner = _addRanked("winner", 1, 100); // index 0
        address middle = _addRanked("middle", 2, 200); // index 1 (unused directly)
        address after_ = _addRanked("after", 3, 300); // index 2
        h.h_setCounts(1, 0, 3);
        h.h_setAccepted(true);
        h.h_setWinner(winner);

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(after_);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, after_);
        assertEq(amount, h.depositAmount());
        middle;
    }

    function test_SettlementOf_Refund_IneligibleBid() public {
        // Covers both a straight majority-vote Ineligible verdict and a dismissed appeal:
        // both leave the bid in state Ineligible, which is the only thing settlementOf reads.
        address bidder = makeAddr("ineligible");
        h.h_addBid(bidder, 1, BidState.Ineligible, false);
        h.h_setCounts(1, 0, 0);

        vm.warp(h.priceRevealStart());
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoEligibleBids));

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_Refund_DebarredBeforeCutoff_Opened() public {
        // Opened and debarred: would otherwise be ranked and hit F3 (AllOffersLapsed).
        address bidder = makeAddr("debarred");
        uint64 vendorId = _registerVendor(bidder, keccak256("debarred"));
        h.h_addBid(bidder, vendorId, BidState.Eligible, false);
        h.h_setOpened(bidder, 100);
        _addRanked("otherRanked", 999, 200);
        h.h_setCounts(1, 0, 2);

        vm.warp(h.priceRevealStart() - 100);
        vm.prank(registrar);
        registry.debarVendor(vendorId, keccak256("reason")); // before priceRevealStart

        _warpToAllOffersLapsed(1); // only otherRanked counts toward rankedCount now
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.AllOffersLapsed));

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_Refund_DebarredBeforeCutoff_NotOpened() public {
        // Eligible, never opened, under NoRankedBids: satisfies every F2 condition except
        // debarment, which must still save it from forfeiture.
        address bidder = makeAddr("debarredHidden");
        uint64 vendorId = _registerVendor(bidder, keccak256("debarredHidden"));
        h.h_addBid(bidder, vendorId, BidState.Eligible, false);
        h.h_setCounts(1, 0, 1);

        vm.warp(h.priceRevealStart() - 100);
        vm.prank(registrar);
        registry.debarVendor(vendorId, keccak256("reason")); // before priceRevealStart

        vm.warp(h.priceRevealEnd()); // never opened -> rankedCount() == 0 -> NoRankedBids
        assertEq(uint256(h.terminalCause()), uint256(TerminalCause.NoRankedBids));

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder);
        assertEq(amount, h.depositAmount());
    }

    function test_SettlementOf_Refund_AllBidsOfFailedTenderExceptF1() public {
        address stuckRevealed = makeAddr("stuckRevealed");
        h.h_addBid(stuckRevealed, 1, BidState.Revealed, false);

        address stuckEligible = makeAddr("stuckEligible");
        h.h_addBid(stuckEligible, 2, BidState.Eligible, false); // never opened

        address stuckAppealed = makeAddr("stuckAppealed");
        h.h_addBid(stuckAppealed, 3, BidState.Appealed, false);

        h.h_setCounts(1, 1, 1); // unresolved = 1 at priceRevealStart -> Failed

        vm.warp(h.priceRevealStart());
        assertEq(uint256(h.currentPhase()), uint256(Phase.Failed));

        (Settlement outcomeRevealed, address recipientRevealed, uint256 amountRevealed) =
            h.settlementOf(stuckRevealed);
        assertEq(uint256(outcomeRevealed), uint256(Settlement.Refund));
        assertEq(recipientRevealed, stuckRevealed);
        assertEq(amountRevealed, h.depositAmount());

        (Settlement outcomeEligible, address recipientEligible, uint256 amountEligible) =
            h.settlementOf(stuckEligible);
        assertEq(uint256(outcomeEligible), uint256(Settlement.Refund));
        assertEq(recipientEligible, stuckEligible);
        assertEq(amountEligible, h.depositAmount());

        (Settlement outcomeAppealed, address recipientAppealed, uint256 amountAppealed) =
            h.settlementOf(stuckAppealed);
        assertEq(uint256(outcomeAppealed), uint256(Settlement.Refund));
        assertEq(recipientAppealed, stuckAppealed);
        assertEq(amountAppealed, h.depositAmount());
    }

    function test_SettlementOf_Refund_PECancelledTenderDoesNotForfeitEligibleNotOpened() public {
        address bidder = makeAddr("eligibleNotOpened");
        h.h_addBid(bidder, 1, BidState.Eligible, false);
        h.h_setCancelledByPE(true); // cause is always CancelledByPE, never in F2's cause set

        (Settlement outcome, address recipient, uint256 amount) = h.settlementOf(bidder);
        assertEq(uint256(outcome), uint256(Settlement.Refund));
        assertEq(recipient, bidder);
        assertEq(amount, h.depositAmount());
    }

    // ==================================================================
    // Settled / settle-once (I11)
    // ==================================================================

    function test_Settle_RevertsWhenPending() public {
        vm.prank(realBidder);
        h.commit(keccak256("p"), keccak256("d"), keccak256("c"));

        vm.expectRevert(Tender.NothingToSettle.selector);
        h.settle(realBidder);
    }

    function test_Settle_RefundPaysBidderAndMarksSettled() public {
        vm.prank(realBidder);
        h.commit(keccak256("p"), keccak256("d"), keccak256("c"));
        vm.prank(realBidder);
        h.withdraw(); // immediately Refund-eligible, even before terminal

        uint256 bidderBalanceBefore = token.balanceOf(realBidder);
        uint256 contractBalanceBefore = token.balanceOf(address(h));

        vm.expectEmit(true, true, false, true);
        emit DepositSettled(realBidder, realBidder, h.depositAmount(), false);
        h.settle(realBidder);

        assertEq(token.balanceOf(realBidder), bidderBalanceBefore + h.depositAmount());
        assertEq(token.balanceOf(address(h)), contractBalanceBefore - h.depositAmount());
        assertEq(h.totalLiabilities(), 0);

        (Settlement outcome,,) = h.settlementOf(realBidder);
        assertEq(uint256(outcome), uint256(Settlement.Settled));
    }

    function test_Settle_RevertsOnSecondCall() public {
        vm.prank(realBidder);
        h.commit(keccak256("p"), keccak256("d"), keccak256("c"));
        vm.prank(realBidder);
        h.withdraw();

        h.settle(realBidder);

        vm.expectRevert(Tender.NothingToSettle.selector);
        h.settle(realBidder);
    }

    function test_Settle_ForfeitPaysTreasury() public {
        vm.prank(realBidder);
        h.commit(keccak256("p"), keccak256("d"), keccak256("c")); // stays Committed forever
        h.h_setCounts(1, 0, 0);

        vm.warp(h.priceRevealStart()); // -> Cancelled / NoEligibleBids, F1 applies

        uint256 treasuryBalanceBefore = token.balanceOf(treasury);

        vm.expectEmit(true, true, false, true);
        emit DepositSettled(realBidder, treasury, h.depositAmount(), true);
        h.settle(realBidder);

        assertEq(token.balanceOf(treasury), treasuryBalanceBefore + h.depositAmount());
        assertEq(h.totalLiabilities(), 0);
    }

    // ==================================================================
    // Direct-transfer accounting (I1)
    // ==================================================================

    function test_Settle_DirectTransferSurplusDoesNotAffectAccounting() public {
        vm.prank(realBidder);
        h.commit(keccak256("p"), keccak256("d"), keccak256("c"));
        vm.prank(realBidder);
        h.withdraw();

        // A surplus direct transfer, bypassing commit(). Not reflected in _totalLiabilities.
        vm.prank(admin);
        token.mint(address(h), DEPOSIT * 5);

        uint256 bidderBalanceBefore = token.balanceOf(realBidder);
        uint256 liabilitiesBefore = h.totalLiabilities();

        h.settle(realBidder);

        assertEq(token.balanceOf(realBidder), bidderBalanceBefore + DEPOSIT);
        assertEq(h.totalLiabilities(), liabilitiesBefore - DEPOSIT);
        // The surplus is untouched and still sits in the contract.
        assertEq(token.balanceOf(address(h)), DEPOSIT * 5);
    }
}
