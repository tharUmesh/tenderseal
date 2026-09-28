// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Bid, BidState, Phase} from "../../src/TenderTypes.sol";
import {TenderTestBase} from "../utils/TenderTestBase.sol";
import {Tender} from "../../src/Tender.sol";
import {TenderHandler} from "./TenderHandler.sol";

/// @dev Invariant suite (SPEC §9, I1-I12) driven by a bounded handler: 5 registered
///      bidders, the tender's own 3 evaluators/PE/authority, bounded forward-only time
///      warps. `foundry.toml` sets runs = 256, depth = 64, fail_on_revert = false.
contract TenderInvariantsTest is TenderTestBase {
    Tender internal tender;
    TenderHandler internal handler;

    uint256 internal constant NUM_BIDDERS = 5;

    function setUp() public override {
        super.setUp();

        address[] memory bidderAddrs = new address[](NUM_BIDDERS);
        uint64[] memory vendorIds = new uint64[](NUM_BIDDERS);
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            bidderAddrs[i] = makeAddr(string.concat("invBidder", vm.toString(i)));
            vendorIds[i] = _registerVendor(bidderAddrs[i], keccak256(abi.encode("invBidder", i)));
        }

        vm.warp(T0 + 1 hours);
        tender = new Tender(_defaultConfig());

        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            vm.prank(admin);
            token.mint(bidderAddrs[i], DEPOSIT * 1000);
            vm.prank(bidderAddrs[i]);
            token.approve(address(tender), type(uint256).max);
        }
        // Funds a non-bidder actor so the handler's directTransfer (surplus, I1) has a
        // source; `pe` never needs its own tokens for anything else.
        vm.prank(admin);
        token.mint(pe, DEPOSIT * 1000);

        address[] memory evaluators = new address[](3);
        evaluators[0] = eval1;
        evaluators[1] = eval2;
        evaluators[2] = eval3;

        handler = new TenderHandler(
            tender,
            registry,
            token,
            pe,
            appealsAuthority,
            treasury,
            evaluators,
            bidderAddrs,
            vendorIds
        );

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ I1, I11

    /// @dev I1: solvency plus an independent deposit ledger. I11 (no over-payment) falls
    ///      out of the same ledger: paid out can never exceed deposited.
    function invariant_I1_SolvencyAndGhostLedger() public view {
        assertGe(token.balanceOf(address(tender)), tender.totalLiabilities());
        uint256 paidOut = handler.ghost_refundedOut() + handler.ghost_forfeitedOut();
        assertLe(paidOut, handler.ghost_depositsIn());
        assertEq(tender.totalLiabilities(), handler.ghost_depositsIn() - paidOut);
    }

    // ------------------------------------------------------------------ I2

    /// @dev I2: every Forfeit the handler observed was independently re-derived (by the
    ///      handler, right before calling settle) to match F1, F2, or F3.
    function invariant_I2_ForfeitureOnlyViaF1F2F3() public view {
        assertEq(handler.ghost_forfeitMismatches(), 0);
    }

    // ------------------------------------------------------------------ I3

    function invariant_I3_ThresholdAndVoteImmutability() public view {
        assertTrue(2 * uint256(tender.threshold()) > tender.evaluatorCount());
        assertEq(handler.ghost_doubleVoteSuccesses(), 0);
    }

    // ------------------------------------------------------------------ I4

    /// @dev No bid may still be Revealed or Appealed (the two "unresolved" states) once
    ///      the tender has reached PriceReveal, Acceptance, or Final.
    function invariant_I4_NoRevealUnlessAllResolved() public view {
        Phase phase = tender.currentPhase();
        bool pastAppealResolution =
            phase == Phase.PriceReveal || phase == Phase.Acceptance || phase == Phase.Final;
        if (!pastAppealResolution) return;

        address[] memory bs = handler.bidders();
        for (uint256 i = 0; i < bs.length; i++) {
            BidState state = tender.getBid(bs[i]).state;
            assertTrue(state != BidState.Revealed && state != BidState.Appealed);
        }
    }

    // ------------------------------------------------------------------ I5

    function invariant_I5_RankingSortedByPriceThenTieRank() public view {
        address[] memory ranked = tender.ranking();
        for (uint256 i = 1; i < ranked.length; i++) {
            Bid memory a = tender.getBid(ranked[i - 1]);
            Bid memory b = tender.getBid(ranked[i]);
            if (a.price == b.price) {
                bytes32 tieA = keccak256(abi.encode(address(tender), a.vendorId));
                bytes32 tieB = keccak256(abi.encode(address(tender), b.vendorId));
                assertLe(uint256(tieA), uint256(tieB));
            } else {
                assertLe(a.price, b.price);
            }
        }
    }

    // ------------------------------------------------------------------ I6

    function invariant_I6_PhaseOrdinalNonDecreasing() public view {
        assertGe(uint256(tender.currentPhase()), handler.ghost_lastPhaseOrdinal());
    }

    // ------------------------------------------------------------------ I7

    function invariant_I7_ParametersAndEvaluatorsUnchanged() public view {
        assertEq(tender.threshold(), 2);
        assertEq(tender.depositAmount(), DEPOSIT);
        assertEq(tender.maxBidders(), 20);
        assertTrue(tender.isEvaluator(eval1));
        assertTrue(tender.isEvaluator(eval2));
        assertTrue(tender.isEvaluator(eval3));
    }

    // ------------------------------------------------------------------ I8

    function invariant_I8_BidderCapAndUniqueness() public view {
        address[] memory bs = tender.bidders();
        assertLe(bs.length, tender.maxBidders());
        for (uint256 i = 0; i < bs.length; i++) {
            for (uint256 j = i + 1; j < bs.length; j++) {
                assertTrue(bs[i] != bs[j]);
            }
        }
    }

    // ------------------------------------------------------------------ I9

    function invariant_I9_RankingExcludesDebarredBeforeCutoff() public view {
        address[] memory ranked = tender.ranking();
        for (uint256 i = 0; i < ranked.length; i++) {
            uint64 vendorId = tender.getBid(ranked[i]).vendorId;
            assertFalse(registry.isDebarredBefore(vendorId, tender.priceRevealStart()));
        }
    }

    // ------------------------------------------------------------------ I10

    function invariant_I10_TerminalIsAbsorbing() public view {
        assertEq(handler.ghost_actionsAfterTerminal(), 0);
    }

    // ------------------------------------------------------------------ I11

    function invariant_I11_SettleExactlyOnce() public view {
        assertEq(handler.ghost_doubleSettleSuccesses(), 0);
    }

    // ------------------------------------------------------------------ I12

    function invariant_I12_WinnerWasEligibleOpenedAndNonExcluded() public view {
        address w = tender.winner();
        if (w == address(0)) return;
        Bid memory bid = tender.getBid(w);
        assertEq(uint256(bid.state), uint256(BidState.Eligible));
        assertTrue(bid.opened);
        assertFalse(registry.isDebarredBefore(bid.vendorId, tender.priceRevealStart()));
    }
}
