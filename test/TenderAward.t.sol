// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {Phase, Settlement, TerminalCause} from "../src/TenderTypes.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `acceptAward` / `acknowledgeAward` tests (SPEC §6.9): award to lowest, non-offeree
///      rejection, re-award after lapse, and all-offers-lapsed.
contract TenderAwardTest is TenderTestBase {
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1"); // cheapest
    address internal bidder2 = makeAddr("bidder2"); // middle
    address internal bidder3 = makeAddr("bidder3"); // most expensive

    bytes32 internal constant DOC_HASH = keccak256("d");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");
    bytes32 internal constant KEY_ENV_REF = keccak256("k");
    bytes32 internal constant REPORT_HASH = keccak256("r");
    uint8 internal constant REASON_COMPLIANT = 1;

    uint256 internal constant PRICE1 = 100_00;
    uint256 internal constant PRICE2 = 200_00;
    uint256 internal constant PRICE3 = 300_00;
    bytes32 internal constant SALT1 = keccak256("salt1");
    bytes32 internal constant SALT2 = keccak256("salt2");
    bytes32 internal constant SALT3 = keccak256("salt3");

    event AwardAccepted(address indexed bidder, uint256 round, uint256 price);
    event AwardAcknowledged(address indexed winner);

    function setUp() public override {
        super.setUp();

        _registerVendor(bidder1, keccak256("bidder1"));
        _registerVendor(bidder2, keccak256("bidder2"));
        _registerVendor(bidder3, keccak256("bidder3"));

        vm.warp(T0 + 1 hours);
        tender = new Tender(_defaultConfig());

        _fundAndApprove(bidder1);
        _fundAndApprove(bidder2);
        _fundAndApprove(bidder3);
    }

    function _fundAndApprove(address who) internal {
        vm.prank(admin);
        token.mint(who, DEPOSIT * 10);
        vm.prank(who);
        token.approve(address(tender), type(uint256).max);
    }

    function _commitment(address bidder, uint256 price, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(tender), bidder, price, DOC_HASH, salt));
    }

    /// @dev Commits, reveals, votes Eligible, and reveals the price for all three bidders,
    ///      producing ranking() == [bidder1 (cheapest), bidder2, bidder3].
    function _setupThreeRankedBidders() internal {
        vm.prank(bidder1);
        tender.commit(_commitment(bidder1, PRICE1, SALT1), DOC_HASH, DOC_CIPHER_REF);
        vm.prank(bidder2);
        tender.commit(_commitment(bidder2, PRICE2, SALT2), DOC_HASH, DOC_CIPHER_REF);
        vm.prank(bidder3);
        tender.commit(_commitment(bidder3, PRICE3, SALT3), DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.prank(bidder1);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(bidder2);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(bidder3);
        tender.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval1);
        tender.castVote(bidder2, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder2, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval1);
        tender.castVote(bidder3, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder3, true, REASON_COMPLIANT, REPORT_HASH);

        vm.warp(tender.priceRevealStart());
        tender.revealPrice(bidder1, PRICE1, SALT1);
        tender.revealPrice(bidder2, PRICE2, SALT2);
        tender.revealPrice(bidder3, PRICE3, SALT3);
    }

    // ==================================================================
    // Award to lowest / offeree checks
    // ==================================================================

    function test_AcceptAward_AwardsToLowestPrice() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd());

        (uint256 round, address offeree,) = tender.currentOffer();
        assertEq(round, 1);
        assertEq(offeree, bidder1);

        vm.expectEmit(true, false, false, true);
        emit AwardAccepted(bidder1, 1, PRICE1);
        vm.prank(bidder1);
        tender.acceptAward();

        assertEq(tender.winner(), bidder1);
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Final));
    }

    function test_AcceptAward_RevertsWhenNonOffereeCalls() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd());

        vm.expectRevert(Tender.NotCurrentOfferee.selector);
        vm.prank(bidder2);
        tender.acceptAward();
    }

    function test_AcceptAward_RevertsWhenRandomAddressCalls() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd());

        vm.expectRevert(Tender.NotCurrentOfferee.selector);
        vm.prank(makeAddr("random"));
        tender.acceptAward();
    }

    function test_AcceptAward_RevertsBeforePriceRevealEnd() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd() - 1);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.PriceReveal));
        vm.prank(bidder1);
        tender.acceptAward();
    }

    // ==================================================================
    // Re-award after lapse
    // ==================================================================

    function test_AcceptAward_ReAwardAfterLapse() public {
        _setupThreeRankedBidders();
        uint64 round1End = tender.priceRevealEnd() + tender.acceptanceWindow();

        // bidder1 (round 1) never accepts; its window lapses.
        vm.warp(round1End);
        (uint256 round, address offeree,) = tender.currentOffer();
        assertEq(round, 2);
        assertEq(offeree, bidder2);

        // bidder1 can no longer accept once its round has passed.
        vm.expectRevert(Tender.NotCurrentOfferee.selector);
        vm.prank(bidder1);
        tender.acceptAward();

        vm.expectEmit(true, false, false, true);
        emit AwardAccepted(bidder2, 2, PRICE2);
        vm.prank(bidder2);
        tender.acceptAward();

        assertEq(tender.winner(), bidder2);
    }

    function test_AcceptAward_AllOffersLapse_NoOneAccepts() public {
        _setupThreeRankedBidders();
        uint64 lapseAt = tender.priceRevealEnd() + 3 * tender.acceptanceWindow();

        vm.warp(lapseAt);
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Cancelled));

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        tender.acceptAward();
    }

    // ==================================================================
    // Settlement integration: winner refunded, lapsed earlier bidder forfeits
    // ==================================================================

    function test_AcceptAward_ThenSettle_WinnerRefundedEarlierBidderForfeits() public {
        _setupThreeRankedBidders();
        uint64 round1End = tender.priceRevealEnd() + tender.acceptanceWindow();
        vm.warp(round1End);
        vm.prank(bidder2);
        tender.acceptAward(); // bidder1's round lapsed; bidder2 wins

        uint256 bidder2BalanceBefore = token.balanceOf(bidder2);
        tender.settle(bidder2);
        assertEq(token.balanceOf(bidder2), bidder2BalanceBefore + tender.depositAmount());

        (Settlement outcome1,,) = tender.settlementOf(bidder1); // ranked before the winner
        assertEq(uint256(outcome1), uint256(Settlement.Forfeit));

        (Settlement outcome3,,) = tender.settlementOf(bidder3); // ranked after the winner
        assertEq(uint256(outcome3), uint256(Settlement.Refund));
    }

    function test_AllOffersLapse_ThenSettle_EveryRankedBidForfeits() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd() + 3 * tender.acceptanceWindow());
        assertEq(uint256(tender.terminalCause()), uint256(TerminalCause.AllOffersLapsed));

        (Settlement outcome1,,) = tender.settlementOf(bidder1);
        (Settlement outcome2,,) = tender.settlementOf(bidder2);
        (Settlement outcome3,,) = tender.settlementOf(bidder3);
        assertEq(uint256(outcome1), uint256(Settlement.Forfeit));
        assertEq(uint256(outcome2), uint256(Settlement.Forfeit));
        assertEq(uint256(outcome3), uint256(Settlement.Forfeit));
    }

    // ==================================================================
    // acknowledgeAward (SPEC §6.9)
    // ==================================================================

    function test_AcknowledgeAward_HappyPath() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd());
        vm.prank(bidder1);
        tender.acceptAward();

        vm.expectEmit(true, false, false, true);
        emit AwardAcknowledged(bidder1);
        vm.prank(pe);
        tender.acknowledgeAward();
    }

    function test_AcknowledgeAward_RevertsWhenNotPE() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd());
        vm.prank(bidder1);
        tender.acceptAward();

        vm.expectRevert(Tender.NotPE.selector);
        vm.prank(bidder1);
        tender.acknowledgeAward();
    }

    function test_AcknowledgeAward_RevertsWhenNotFinal() public {
        _setupThreeRankedBidders();
        vm.warp(tender.priceRevealEnd()); // Acceptance, not yet accepted

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Acceptance));
        vm.prank(pe);
        tender.acknowledgeAward();
    }
}
