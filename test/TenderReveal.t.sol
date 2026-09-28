// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {Bid, BidState, Phase} from "../src/TenderTypes.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev `revealPrice` tests (SPEC §6.8, §5): commitment verification and phase gating.
contract TenderRevealTest is TenderTestBase {
    Tender internal tender;

    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");

    bytes32 internal constant DOC_CIPHER_REF = keccak256("c");
    bytes32 internal constant KEY_ENV_REF = keccak256("k");
    bytes32 internal constant REPORT_HASH = keccak256("r");
    bytes32 internal constant DOC_HASH = keccak256("doc1");
    bytes32 internal constant DOC_HASH_2 = keccak256("doc2");
    bytes32 internal constant SALT = keccak256("salt1");
    uint256 internal constant PRICE = 12_345;

    uint8 internal constant REASON_COMPLIANT = 1;
    uint8 internal constant REASON_SPEC_NONCOMPLIANT = 2;

    event PriceRevealed(address indexed bidder, uint256 price);

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

    function _commitment(address bidder, uint256 price, bytes32 docHash, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(tender), bidder, price, docHash, salt));
    }

    /// @dev Commits `bidder` with `priceCommitment`/`docHash`, reveals the key envelope,
    ///      and votes it Eligible (2 of 3).
    function _makeEligible(address bidder, bytes32 priceCommitment, bytes32 docHash) internal {
        vm.prank(bidder);
        tender.commit(priceCommitment, docHash, DOC_CIPHER_REF);
        vm.warp(tender.submissionDeadline());
        vm.prank(bidder);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder, true, REASON_COMPLIANT, REPORT_HASH);
    }

    // ==================================================================
    // Happy path
    // ==================================================================

    function test_RevealPrice_HappyPath() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        vm.expectEmit(true, false, false, true);
        emit PriceRevealed(bidder1, PRICE);
        tender.revealPrice(bidder1, PRICE, SALT);

        Bid memory bid = tender.getBid(bidder1);
        assertTrue(bid.opened);
        assertEq(bid.price, PRICE);
    }

    function test_RevealPrice_CallableByAnyone() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        address stranger = makeAddr("stranger");
        vm.expectEmit(true, false, false, true);
        emit PriceRevealed(bidder1, PRICE); // attributed to the bidder, not the caller
        vm.prank(stranger);
        tender.revealPrice(bidder1, PRICE, SALT);

        Bid memory bid = tender.getBid(bidder1);
        assertTrue(bid.opened);
        assertEq(bid.price, PRICE);
    }

    // ==================================================================
    // Commitment verification failures (SPEC §5)
    // ==================================================================

    function test_RevealPrice_RevertsOnWrongPrice() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder1, PRICE + 1, SALT);
    }

    function test_RevealPrice_RevertsOnWrongSalt() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder1, PRICE, keccak256("wrong-salt"));
    }

    function test_RevealPrice_RevertsOnWrongBidder() public {
        // Two real, independently eligible bidders with distinct secrets. bidder1's real
        // price/salt cannot open bidder2's commitment merely by naming bidder2 as the
        // `bidder` argument: the address is baked into the hash on both sides. Both bids
        // are committed first (while still Open), then revealed/voted together, since
        // _makeEligible would otherwise advance time past Open before the second commit.
        uint256 price2 = PRICE + 999;
        bytes32 salt2 = keccak256("salt2");
        bytes32 commitment1 = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        bytes32 commitment2 = _commitment(bidder2, price2, DOC_HASH, salt2);

        vm.prank(bidder1);
        tender.commit(commitment1, DOC_HASH, DOC_CIPHER_REF);
        vm.prank(bidder2);
        tender.commit(commitment2, DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.prank(bidder1);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(bidder2);
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

        vm.warp(tender.priceRevealStart());
        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder2, PRICE, SALT); // bidder1's secrets, claimed as bidder2's
    }

    function test_RevealPrice_RevertsOnWrongDocHash() public {
        // Commitment was built with DOC_HASH, but the bid's docHash param is DOC_HASH_2.
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH_2); // mismatched docHash at commit time
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_ReplaceCommitment_RevealUsesNewDocHash() public {
        bytes32 oldCommitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        vm.prank(bidder1);
        tender.commit(oldCommitment, DOC_HASH, DOC_CIPHER_REF);

        // Replace with a commitment built against DOC_HASH_2, same price/salt.
        bytes32 newCommitment = _commitment(bidder1, PRICE, DOC_HASH_2, SALT);
        vm.prank(bidder1);
        tender.replaceCommitment(newCommitment, DOC_HASH_2, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.prank(bidder1);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder1, true, REASON_COMPLIANT, REPORT_HASH);

        vm.warp(tender.priceRevealStart());
        // Reveals correctly using the bid's *current* (new) docHash, not the original.
        tender.revealPrice(bidder1, PRICE, SALT);
        assertTrue(tender.getBid(bidder1).opened);
    }

    function test_RevealPrice_RevertsOnWrongChainId() public {
        bytes32 wrongChainCommitment = keccak256(
            abi.encode(block.chainid + 1, address(tender), bidder1, PRICE, DOC_HASH, SALT)
        );
        _makeEligible(bidder1, wrongChainCommitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_RevealPrice_RevertsOnWrongContract() public {
        bytes32 wrongContractCommitment =
            keccak256(abi.encode(block.chainid, address(0x1234), bidder1, PRICE, DOC_HASH, SALT));
        _makeEligible(bidder1, wrongContractCommitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_RevealPrice_RevertsOnZeroPrice() public {
        // The commitment itself was built with price = 0 (hash matches), but price > 0
        // is still required.
        bytes32 zeroPriceCommitment = _commitment(bidder1, 0, DOC_HASH, SALT);
        _makeEligible(bidder1, zeroPriceCommitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());

        vm.expectRevert(Tender.InvalidOpening.selector);
        tender.revealPrice(bidder1, 0, SALT);
    }

    // ==================================================================
    // State / phase gating
    // ==================================================================

    function test_RevealPrice_RevertsWhenAlreadyOpened() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealStart());
        tender.revealPrice(bidder1, PRICE, SALT);

        vm.expectRevert(Tender.AlreadyOpened.selector);
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_RevealPrice_RevertsWhenNotEligible_Committed() public {
        // bidder1 commits but never reveals its key envelope, staying Committed forever
        // (the derived F1 / ForfeitedF1 status). A second, genuinely eligible bidder
        // keeps the tender progressing into PriceReveal instead of collapsing to
        // Cancelled/NoEligibleBids.
        vm.prank(bidder1);
        tender.commit(_commitment(bidder1, PRICE, DOC_HASH, SALT), DOC_HASH, DOC_CIPHER_REF);

        bytes32 commitment2 = _commitment(bidder2, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder2, commitment2, DOC_HASH);

        vm.warp(tender.priceRevealStart());
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Committed));
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_RevealPrice_RevertsWhenNotEligible_Ineligible() public {
        // Both bidders are committed first (while still Open), then revealed and voted
        // together: bidder1 -> Ineligible (2 of 3 vote ineligible), bidder2 -> Eligible,
        // which keeps the tender progressing into PriceReveal.
        bytes32 commitment1 = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        bytes32 commitment2 = _commitment(bidder2, PRICE + 1, DOC_HASH, keccak256("salt2"));

        vm.prank(bidder1);
        tender.commit(commitment1, DOC_HASH, DOC_CIPHER_REF);
        vm.prank(bidder2);
        tender.commit(commitment2, DOC_HASH, DOC_CIPHER_REF);

        vm.warp(tender.submissionDeadline());
        vm.prank(bidder1);
        tender.postKeyEnvelope(KEY_ENV_REF);
        vm.prank(bidder2);
        tender.postKeyEnvelope(KEY_ENV_REF);

        vm.warp(tender.techRevealEnd());
        vm.prank(eval1);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder1, false, REASON_SPEC_NONCOMPLIANT, REPORT_HASH);
        vm.prank(eval1);
        tender.castVote(bidder2, true, REASON_COMPLIANT, REPORT_HASH);
        vm.prank(eval2);
        tender.castVote(bidder2, true, REASON_COMPLIANT, REPORT_HASH);

        assertEq(uint256(tender.getBid(bidder1).state), uint256(BidState.Ineligible));

        vm.warp(tender.priceRevealStart());
        vm.expectRevert(
            abi.encodeWithSelector(Tender.InvalidBidState.selector, BidState.Ineligible)
        );
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_RevealPrice_RevertsBeforePriceRevealStart() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealStart() - 1);

        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.AppealResolution));
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    function test_RevealPrice_RevertsAtPriceRevealEnd() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);
        vm.warp(tender.priceRevealEnd());

        // No bid opened yet -> rankedCount() == 0 -> Cancelled/NoRankedBids.
        vm.expectRevert(abi.encodeWithSelector(Tender.WrongPhase.selector, Phase.Cancelled));
        tender.revealPrice(bidder1, PRICE, SALT);
    }

    // ==================================================================
    // Debarment (SPEC §5, §6.8)
    // ==================================================================

    function test_RevealPrice_DebarredBidderCanRevealButExcludedFromRanking() public {
        bytes32 commitment = _commitment(bidder1, PRICE, DOC_HASH, SALT);
        _makeEligible(bidder1, commitment, DOC_HASH);

        uint64 vendorId = tender.getBid(bidder1).vendorId;
        vm.warp(tender.priceRevealStart() - 100);
        vm.prank(registrar);
        registry.debarVendor(vendorId, keccak256("reason"));

        vm.warp(tender.priceRevealStart());
        tender.revealPrice(bidder1, PRICE, SALT); // still succeeds

        assertTrue(tender.getBid(bidder1).opened);
        assertEq(tender.rankedCount(), 0); // but excluded from ranking
    }
}
