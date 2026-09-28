// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Bid, BidState, Phase} from "../../src/TenderTypes.sol";
import {TenderTestBase} from "../utils/TenderTestBase.sol";
import {Tender} from "../../src/Tender.sol";
import {TenderHandler} from "./TenderHandler.sol";

/// @dev Invariant suite (SPEC §9, I1-I12) driven by a bounded handler: 5 registered
///      bidders, the tender's own 3 evaluators/PE/authority, bounded forward-only time
///      warps. `foundry.toml` sets runs = 256, fail_on_revert = false; depth is raised to
///      500 for this contract specifically (Step 7b item 1).
///
///      Vacuity check (see `afterInvariant`): even after depth 64->500, four separate
///      warp-collapse guards (`_clampWarpTarget`), and guided bidder/evaluator targeting
///      (`_bidderWithState`/`_evaluatorWhoHasntVoted`) -- each of which measurably helped
///      (vote successes went 0 -> 10 -> 56 across these changes) -- PriceReveal/
///      Acceptance/Final are still reached in well under 20% of runs (see the Step 7b
///      report for the exact numbers). This is a genuine, reported limitation of
///      unguided action-level fuzzing for a protocol this deep (5 actors x 3 evaluators
///      x ~19 actions x 6 sequential preconditions before any late phase is reachable at
///      all), not a defect papered over: the late-phase/settlement properties this
///      handler under-explores (award-to-lowest, F2/F3 forfeiture, re-award after lapse)
///      are instead covered deterministically by TenderAward.t.sol, TenderScenarios.t.sol
///      and TenderSettle.t.sol. The invariant suite's real contribution is checking I1/
///      I3/I6/I7/I8/I10/I11 hold under genuinely random *early/mid*-lifecycle sequences,
///      which it does exercise heavily (Open 93%, TechReveal 30%, Evaluation 12%).
/// forge-config: default.invariant.depth = 500
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

        targetContract(address(handler));
    }

    // ------------------------------------------------------------------ vacuity check (Step 7b, item 1)

    /// @dev Runs once per invariant run. Prints one CSV-ish line per run so the agent
    ///      driving this suite can compute, across all `runs`, what fraction of sequences
    ///      actually reached each phase, and how many of each action succeeded (settles
    ///      broken down by refund vs. F1/F2/F3) -- a vacuity check on the whole suite.
    function afterInvariant() public {
        string memory phases = _phaseFlags();
        string memory actions = _actionCounts();
        string memory line = string.concat("PHASELOG,", phases, ",", actions);
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
