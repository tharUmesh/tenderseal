// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Tender} from "../src/Tender.sol";
import {Bid, BidState, Phase, TerminalCause} from "../src/TenderTypes.sol";
import {TenderHarness} from "./harness/TenderHarness.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `commit` / `replaceCommitment` / `withdraw` tests (SPEC §6.1-6.3).
contract TenderCommitTest is TenderTestBase {
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");
    uint64 internal vendorId1;
    uint64 internal vendorId2;

    bytes32 internal constant PRICE_COMMIT = keccak256("price-commitment-1");
    bytes32 internal constant DOC_HASH = keccak256("doc-hash-1");
    bytes32 internal constant DOC_CIPHER_REF = keccak256("doc-cipher-ref-1");

    event BidCommitted(
        address indexed bidder,
        uint64 indexed vendorId,
        bytes32 priceCommitment,
        bytes32 docHash,
        bytes32 docCipherRef
    );
    event CommitmentReplaced(
        address indexed bidder, bytes32 priceCommitment, bytes32 docHash, bytes32 docCipherRef
    );
    event BidWithdrawn(address indexed bidder);

    function setUp() public override {
        super.setUp(); // warps to T0, deploys registry + token

        vendorId1 = _registerVendor(bidder1, keccak256("bidder1-identity"));
        vendorId2 = _registerVendor(bidder2, keccak256("bidder2-identity"));

        vm.warp(T0 + 1 hours); // createdAt = T0 + 1h, strictly after both registrations
        tender = new Tender(_defaultConfig());

        _fundAndApprove(tender, bidder1, DEPOSIT * 10);
        _fundAndApprove(tender, bidder2, DEPOSIT * 10);
    }

    function _fundAndApprove(Tender t, address who, uint256 amount) internal {
        vm.prank(admin);
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(t), amount);
    }

    // ------------------------------------------------------------------ commit: happy path

    function test_Commit_TransfersDepositAndStoresBid() public {
        uint256 balanceBefore = token.balanceOf(bidder1);

        vm.expectEmit(true, true, false, true);
        emit BidCommitted(bidder1, vendorId1, PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        assertEq(token.balanceOf(bidder1), balanceBefore - DEPOSIT);
        assertEq(token.balanceOf(address(tender)), DEPOSIT);
        assertEq(tender.totalLiabilities(), DEPOSIT);

        address[] memory bidders_ = tender.bidders();
        assertEq(bidders_.length, 1);
        assertEq(bidders_[0], bidder1);

        Bid memory bid = _bidOf(bidder1);
        assertEq(bid.vendorId, vendorId1);
        assertEq(uint256(bid.state), uint256(BidState.Committed));
        assertEq(bid.priceCommitment, PRICE_COMMIT);
        assertEq(bid.docHash, DOC_HASH);
        assertEq(bid.docCipherRef, DOC_CIPHER_REF);
    }

    function test_Commit_MultipleBiddersTracked() public {
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.prank(bidder2);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        assertEq(tender.bidders().length, 2);
        assertEq(tender.totalLiabilities(), DEPOSIT * 2);
        assertEq(token.balanceOf(address(tender)), DEPOSIT * 2);
    }

    // ------------------------------------------------------------------ commit: reverts

    function test_Commit_RevertsWhenUnregistered() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(Tender.NotRegisteredVendor.selector);
        vm.prank(stranger);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsWhenRegisteredAtCreatedAt() public {
        address lateVendor = makeAddr("lateVendor");
        vm.warp(tender.createdAt());
        uint64 vid = _registerVendor(lateVendor, keccak256("lateVendor"));

        vm.expectRevert(abi.encodeWithSelector(Tender.RegisteredTooLate.selector, vid));
        vm.prank(lateVendor);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsWhenRegisteredAfterCreatedAt() public {
        address lateVendor = makeAddr("lateVendor");
        vm.warp(tender.createdAt() + 1);
        uint64 vid = _registerVendor(lateVendor, keccak256("lateVendor"));

        vm.expectRevert(abi.encodeWithSelector(Tender.RegisteredTooLate.selector, vid));
        vm.prank(lateVendor);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsWhenDebarred() public {
        vm.prank(registrar);
        registry.debarVendor(vendorId1, keccak256("debarment-reason"));

        vm.expectRevert(abi.encodeWithSelector(Tender.VendorIsDebarred.selector, vendorId1));
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsOnDuplicateBid() public {
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.expectRevert(Tender.BidExists.selector);
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsOnRecommitAfterWithdraw() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        tender.withdraw();
        vm.expectRevert(Tender.BidExists.selector);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.stopPrank();
    }

    function test_Commit_RevertsWhenMaxBiddersReached() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.maxBidders = 1;
        Tender smallTender = new Tender(config);
        _fundAndApprove(smallTender, bidder1, DEPOSIT);
        _fundAndApprove(smallTender, bidder2, DEPOSIT);

        vm.prank(bidder1);
        smallTender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.expectRevert(Tender.TooManyBidders.selector);
        vm.prank(bidder2);
        smallTender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsOnZeroPriceCommitment() public {
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(bidder1);
        tender.commit(bytes32(0), DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsOnZeroDocHash() public {
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, bytes32(0), DOC_CIPHER_REF);
    }

    function test_Commit_RevertsOnZeroDocCipherRef() public {
        vm.expectRevert(Tender.ZeroHash.selector);
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, bytes32(0));
    }

    function test_Commit_AllowedAtSubmissionDeadlineMinusOne() public {
        vm.warp(tender.submissionDeadline() - 1);
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        assertEq(uint256(_bidOf(bidder1).state), uint256(BidState.Committed));
    }

    function test_Commit_RevertsAtSubmissionDeadline() public {
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF); // active bid exists

        vm.warp(tender.submissionDeadline());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.TechReveal));

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.TechReveal));
        vm.prank(bidder2);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsAfterSubmissionDeadline() public {
        vm.warp(tender.submissionDeadline() + 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsWhenCancelledByPE() public {
        // cancel() itself is Step 6; use the harness to set the recorded fact directly.
        TenderHarness h = new TenderHarness(_defaultConfig());
        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_Commit_RevertsOnInsufficientAllowance() public {
        vm.prank(bidder1);
        token.approve(address(tender), 0); // revoke the allowance granted in setUp

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(tender), 0, DEPOSIT
            )
        );
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    // ------------------------------------------------------------------ replaceCommitment

    function test_ReplaceCommitment_OverwritesFieldsAndKeepsDeposit() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        bytes32 newPrice = keccak256("price-2");
        bytes32 newDoc = keccak256("doc-2");
        bytes32 newRef = keccak256("ref-2");

        vm.expectEmit(true, false, false, true);
        emit CommitmentReplaced(bidder1, newPrice, newDoc, newRef);
        tender.replaceCommitment(newPrice, newDoc, newRef);
        vm.stopPrank();

        Bid memory bid = _bidOf(bidder1);
        assertEq(bid.priceCommitment, newPrice);
        assertEq(bid.docHash, newDoc);
        assertEq(bid.docCipherRef, newRef);
        assertEq(uint256(bid.state), uint256(BidState.Committed));
        assertEq(tender.totalLiabilities(), DEPOSIT);
        assertEq(token.balanceOf(address(tender)), DEPOSIT);
    }

    function test_ReplaceCommitment_RevertsWhenNoBid() public {
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.None));
        vm.prank(bidder1);
        tender.replaceCommitment(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_ReplaceCommitment_RevertsWhenWithdrawn() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        tender.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Withdrawn));
        tender.replaceCommitment(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.stopPrank();
    }

    function test_ReplaceCommitment_RevertsOnZeroHash() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        vm.expectRevert(Tender.ZeroHash.selector);
        tender.replaceCommitment(bytes32(0), DOC_HASH, DOC_CIPHER_REF);
        vm.stopPrank();
    }

    function test_ReplaceCommitment_RevertsAtWrongPhase() public {
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.TechReveal));
        vm.prank(bidder1);
        tender.replaceCommitment(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    function test_ReplaceCommitment_RevertsWhenCancelledByPE() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1, DEPOSIT);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        h.replaceCommitment(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
    }

    // ------------------------------------------------------------------ withdraw

    function test_Withdraw_MarksWithdrawnAndEmits() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.expectEmit(true, false, false, true);
        emit BidWithdrawn(bidder1);
        tender.withdraw();
        vm.stopPrank();

        assertEq(uint256(_bidOf(bidder1).state), uint256(BidState.Withdrawn));
    }

    function test_Withdraw_DoesNotMoveTokens() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        uint256 contractBalanceAfterCommit = token.balanceOf(address(tender));
        uint256 liabilitiesAfterCommit = tender.totalLiabilities();

        tender.withdraw();
        vm.stopPrank();

        // Step 3 only marks the bid Withdrawn; the actual refund is `settle()` (Step 4).
        assertEq(token.balanceOf(address(tender)), contractBalanceAfterCommit);
        assertEq(tender.totalLiabilities(), liabilitiesAfterCommit);
    }

    function test_Withdraw_DecrementsActiveBidCount() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        tender.withdraw();
        vm.stopPrank();

        // The only bid is now Withdrawn, so _activeBidCount is back to 0: at the
        // submission deadline the tender is Cancelled/NoBids, not TechReveal.
        vm.warp(tender.submissionDeadline());
        assertEq(uint256(tender.currentPhase()), uint256(Phase.Cancelled));
        assertEq(uint256(tender.terminalCause()), uint256(TerminalCause.NoBids));
    }

    function test_Withdraw_RevertsWhenNoBid() public {
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.None));
        vm.prank(bidder1);
        tender.withdraw();
    }

    function test_Withdraw_RevertsWhenAlreadyWithdrawn() public {
        vm.startPrank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);
        tender.withdraw();
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Withdrawn));
        tender.withdraw();
        vm.stopPrank();
    }

    function test_Withdraw_RevertsAtWrongPhase() public {
        vm.prank(bidder1);
        tender.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.TechReveal));
        vm.prank(bidder1);
        tender.withdraw();
    }

    function test_Withdraw_RevertsWhenCancelledByPE() public {
        TenderHarness h = new TenderHarness(_defaultConfig());
        _fundAndApprove(h, bidder1, DEPOSIT);
        vm.prank(bidder1);
        h.commit(PRICE_COMMIT, DOC_HASH, DOC_CIPHER_REF);

        h.h_setCancelledByPE(true);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        vm.prank(bidder1);
        h.withdraw();
    }

    // ------------------------------------------------------------------ helpers

    function _bidOf(address bidder) internal view returns (Bid memory) {
        return tender.getBid(bidder);
    }
}
