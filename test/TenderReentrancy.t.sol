// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Tender} from "../src/Tender.sol";
import {BidState, Settlement} from "../src/TenderTypes.sol";
import {MaliciousReentrantToken} from "./MaliciousReentrantToken.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev Reentrancy tests: a malicious ERC20 token calls back into `settle`/`commit`
///      (the two `nonReentrant` functions) before its own transfer completes. OZ's
///      `ReentrancyGuard` uses one lock per contract, so the reentrant call must be
///      blocked regardless of which nonReentrant function it targets.
contract TenderReentrancyTest is TenderTestBase {
    MaliciousReentrantToken internal evilToken;
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");

    bytes32 internal constant DOC_HASH = keccak256("d");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");

    function setUp() public override {
        super.setUp();

        evilToken = new MaliciousReentrantToken();

        _registerVendor(bidder1, keccak256("bidder1"));
        _registerVendor(bidder2, keccak256("bidder2"));

        vm.warp(T0 + 1 hours);
        Tender.TenderConfig memory config = _defaultConfig();
        config.token = address(evilToken);
        tender = new Tender(config);

        evilToken.mint(bidder1, DEPOSIT * 10);
        vm.prank(bidder1);
        evilToken.approve(address(tender), type(uint256).max);

        evilToken.mint(bidder2, DEPOSIT * 10);
        vm.prank(bidder2);
        evilToken.approve(address(tender), type(uint256).max);
    }

    function test_Reentrancy_SettleBlocksReentrantSettle() public {
        // bidder1 withdraws before terminal: immediately Refund-eligible (settle() does
        // not require msg.sender to be the bidder, so this is a clean reentrant target).
        vm.startPrank(bidder1);
        tender.commit(keccak256("p1"), DOC_HASH, DOC_CIPHER_REF);
        tender.withdraw();
        vm.stopPrank();

        evilToken.arm(address(tender), abi.encodeCall(Tender.settle, (bidder1)));

        uint256 balanceBefore = evilToken.balanceOf(bidder1);
        tender.settle(bidder1); // outer call, callable by anyone

        assertTrue(evilToken.lastReentryAttempted());
        assertFalse(evilToken.lastReentryOk());
        assertEq(
            bytes4(evilToken.lastReentryReturnData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );

        // Exactly one payout, not two.
        assertEq(evilToken.balanceOf(bidder1), balanceBefore + tender.depositAmount());
        assertEq(uint256(_settlementOutcome(bidder1)), uint256(Settlement.Settled));
        assertEq(tender.totalLiabilities(), 0);
    }

    function test_Reentrancy_CommitBlocksReentrantSettle() public {
        // bidder2 is already Refund-eligible before bidder1's commit runs.
        vm.startPrank(bidder2);
        tender.commit(keccak256("p2"), DOC_HASH, DOC_CIPHER_REF);
        tender.withdraw();
        vm.stopPrank();

        evilToken.arm(address(tender), abi.encodeCall(Tender.settle, (bidder2)));

        vm.prank(bidder1);
        tender.commit(keccak256("p1"), DOC_HASH, DOC_CIPHER_REF); // outer call succeeds

        assertTrue(evilToken.lastReentryAttempted());
        assertFalse(evilToken.lastReentryOk());
        assertEq(
            bytes4(evilToken.lastReentryReturnData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );

        // bidder1's commit went through normally; bidder2's settlement never happened
        // (the reentrant attempt to settle it was blocked, not silently dropped).
        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Committed));
        (Settlement outcome,,) = tender.settlementOf(bidder2);
        assertEq(uint256(outcome), uint256(Settlement.Refund)); // still unsettled
    }

    function _settlementOutcome(address bidder) internal view returns (Settlement outcome) {
        (outcome,,) = tender.settlementOf(bidder);
    }
}
