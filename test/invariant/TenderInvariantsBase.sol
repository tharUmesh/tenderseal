// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Bid, BidState, Phase} from "../../src/TenderTypes.sol";
import {TenderTestBase} from "../utils/TenderTestBase.sol";
import {Tender} from "../../src/Tender.sol";
import {TenderHandler} from "./TenderHandler.sol";

/// @dev Shared deployment, logging and invariant_I1..I12 checks for every invariant suite
///      (SPEC §9). A suite is either the "cold start" suite (`TenderInvariantsTest`,
///      handler-driven from tender creation) or a checkpoint suite (`TenderInvariantsCP1..
///      CP4Test`) that drives the SAME handler through the SAME functions in `setUp` to
///      reach a fixed lifecycle checkpoint before randomness takes over -- see each CP
///      file's doc comment for exactly which functions/timestamps it uses and why.
///
///      All invariant_I1..I12 bodies are byte-for-byte the ones from the original
///      cold-start suite (Step 7b/7c): reusing them here, unchanged, is what lets a
///      checkpoint suite claim it is exercising "the same invariants" rather than a
///      parallel, possibly-diverging copy.
abstract contract TenderInvariantsBase is TenderTestBase {
    Tender internal tender;
    TenderHandler internal handler;

    uint256 internal constant NUM_BIDDERS = 5;

    /// @dev One short tag per suite (e.g. "CP0", "CP1") so every suite can append to the
    ///      same shared CSV log (`foundry.toml`'s `fs_permissions` only allow this one
    ///      path) without their lines being ambiguous.
    function _suiteTag() internal pure virtual returns (string memory);

    /// @dev Deploys a fresh Tender + handler with 5 registered bidders and the tender's
    ///      own 3 evaluators/PE/authority, funds and approves every bidder, and sets the
    ///      handler as the fuzz target. Returns the bidder addresses/vendorIds so a
    ///      checkpoint suite's `setUp` can drive specific bidders toward its checkpoint.
    function _deployTenderAndHandler()
        internal
        returns (address[] memory bidderAddrs, uint64[] memory vendorIds)
    {
        bidderAddrs = new address[](NUM_BIDDERS);
        vendorIds = new uint64[](NUM_BIDDERS);
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

        Tender.Schedule memory s = _defaultSchedule();
        handler = new TenderHandler(
            tender,
            registry,
            token,
            pe,
            appealsAuthority,
            treasury,
            evaluators,
            bidderAddrs,
            vendorIds,
            TenderHandler.ScheduleConfig({
                submissionDeadline: s.submissionDeadline,
                techRevealEnd: s.techRevealEnd,
                evaluationEnd: s.evaluationEnd,
                appealFilingEnd: s.appealFilingEnd,
                priceRevealStart: s.priceRevealStart,
                priceRevealEnd: s.priceRevealEnd,
                acceptanceWindow: s.acceptanceWindow,
                threshold: 2
            })
        );

        // Explicit selector allowlist (Step 7d): `targetContract` alone would also expose
        // `recordDebarredBeforeCutoff` (added for CP3/CP4's shadow bookkeeping, Step 7d
        // item 1) to the fuzzer, which would then call it with arbitrary random addresses
        // -- falsely "debarring" real bidders in the shadow model with no matching real
        // debarment, corrupting I2's ground truth. It is a checkpoint-setup-only function,
        // never one of the handler's own randomized actions, so it is excluded here.
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = handler.warp.selector;
        selectors[1] = handler.warpToNextBoundary.selector;
        selectors[2] = handler.commit.selector;
        selectors[3] = handler.replaceCommitment.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.postKeyEnvelope.selector;
        selectors[6] = handler.declareConflict.selector;
        selectors[7] = handler.castVote.selector;
        selectors[8] = handler.fileAppeal.selector;
        selectors[9] = handler.resolveEscalation.selector;
        selectors[10] = handler.resolveAppeal.selector;
        selectors[11] = handler.cancel.selector;
        selectors[12] = handler.revealPrice.selector;
        selectors[13] = handler.acceptAward.selector;
        selectors[14] = handler.acknowledgeAward.selector;
        selectors[15] = handler.settle.selector;
        selectors[16] = handler.directTransfer.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------------------------------------------------ vacuity check (Step 7b/7d)

    /// @dev Runs once per invariant run. Prints one CSV-ish line per run, tagged with the
    ///      suite name, so the agent driving these suites can compute -- per suite --
    ///      what fraction of runs reached each phase and how many of each action
    ///      succeeded (settles broken down by refund vs. F1/F2/F3).
    function afterInvariant() public {
        string memory phases = _phaseFlags();
        string memory actions = _actionCounts();
        string memory line = string.concat("PHASELOG,", _suiteTag(), ",", phases, ",", actions);
        console.log(line);
        vm.writeLine("test/invariant/.phase-reach-log.csv", line);
    }

    function _phaseFlags() internal view returns (string memory) {
        string memory a = string.concat(
            _flag(Phase.Open), ",", _flag(Phase.TechReveal), ",", _flag(Phase.Evaluation)
        );
        string memory b = string.concat(
            _flag(Phase.AppealFiling),
            ",",
            _flag(Phase.AppealResolution),
            ",",
            _flag(Phase.PriceReveal)
        );
        string memory c = string.concat(
            _flag(Phase.Acceptance), ",", _flag(Phase.Final), ",", _flag(Phase.Cancelled)
        );
        return string.concat(a, ",", b, ",", c, ",", _flag(Phase.Failed));
    }

    function _actionCounts() internal view returns (string memory) {
        string memory a = string.concat(
            vm.toString(handler.ghost_commitSuccesses()),
            ",",
            vm.toString(handler.ghost_voteSuccesses()),
            ",",
            vm.toString(handler.ghost_appealSuccesses())
        );
        string memory b = string.concat(
            vm.toString(handler.ghost_revealSuccesses()),
            ",",
            vm.toString(handler.ghost_acceptSuccesses()),
            ",",
            vm.toString(handler.ghost_settleRefundCount())
        );
        string memory c = string.concat(
            vm.toString(handler.ghost_settleForfeitF1Count()),
            ",",
            vm.toString(handler.ghost_settleForfeitF2Count()),
            ",",
            vm.toString(handler.ghost_settleForfeitF3Count())
        );
        return string.concat(a, ",", b, ",", c);
    }

    function _flag(Phase p) internal view returns (string memory) {
        return handler.ghost_phaseSeenThisRun(uint256(p)) ? "1" : "0";
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
