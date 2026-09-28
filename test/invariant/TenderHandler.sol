// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tender} from "../../src/Tender.sol";
import {VendorRegistry} from "../../src/VendorRegistry.sol";
import {MockTLKR} from "../../src/MockTLKR.sol";
import {BidState, Phase, Settlement, TerminalCause} from "../../src/TenderTypes.sol";

/// @dev Bounded invariant handler: a fixed cast of actors (bidders, the tender's own
///      evaluators/PE/authority) drive every state-changing Tender function through
///      try/catch, so illegal calls are simply skipped rather than failing the run
///      (`fail_on_revert = false`). Time only ever moves forward, by a bounded amount.
///
///      Besides the usual ghost ledger, this handler maintains a full SHADOW state
///      machine (shadow_state, shadow_opened, vote tallies, the three counters, and a
///      shadow ranking/phase/settlement computation) updated only from the *outcome of
///      the handler's own successful calls* -- never by reading Tender's derived views
///      (getBid/currentPhase/terminalCause/ranking/winner). I2's check compares the
///      real `settle()` outcome against this independently-maintained shadow, so a bug
///      anywhere in the contract's bookkeeping (a counter, a state transition, the sort)
///      would surface as a mismatch, not just a bug in the final F1/F2/F3 branch.
contract TenderHandler is Test {
    Tender public immutable tender;
    VendorRegistry public immutable registry;
    MockTLKR public immutable token;
    address public immutable pe;
    address public immutable appealsAuthority;
    address public immutable treasury;

    // Independently-known configuration (supplied by the test, matching what it passed
    // to `_defaultConfig()`/the constructor) -- read here, never fetched from `tender`.
    uint64 public immutable shadowSubmissionDeadline;
    uint64 public immutable shadowTechRevealEnd;
    uint64 public immutable shadowEvaluationEnd;
    uint64 public immutable shadowAppealFilingEnd;
    uint64 public immutable shadowPriceRevealStart;
    uint64 public immutable shadowPriceRevealEnd;
    uint64 public immutable shadowAcceptanceWindow;
    uint8 public immutable shadowThreshold;

    address[] internal _evaluators;
    address[] internal _bidders;
    uint64[] internal _vendorIds;

    // ---- Ghost ledger (I1, I11) -------------------------------------------------

    uint256 public ghost_depositsIn;
    uint256 public ghost_refundedOut;
    uint256 public ghost_forfeitedOut;
    uint256 public ghost_lastPhaseOrdinal;
    bool public ghost_wasTerminal;
    uint256 public ghost_actionsAfterTerminal;
    uint256 public ghost_doubleSettleSuccesses;
    uint256 public ghost_doubleVoteSuccesses;
    uint256 public ghost_forfeitMismatches;

    mapping(address => bool) public ghost_hasCommittedSecret;
    mapping(address => uint256) public ghost_price;
    mapping(address => bytes32) public ghost_docHash;
    mapping(address => bytes32) public ghost_salt;
    mapping(address => bool) public ghost_settledBefore;
    mapping(address => mapping(address => bool)) public ghost_votedBefore; // [evaluator][bidder]

    // ---- Shadow state machine, built only from this handler's own successes -----

    bool public ghost_cancelledByPE;
    uint64 public ghost_cancelledAt;
    bool public ghost_accepted;
    address public ghost_winner;

    mapping(address => BidState) public shadow_state;
    mapping(address => bool) public shadow_opened;
    mapping(address => uint8) public shadow_eligibleVotes;
    mapping(address => uint8) public shadow_ineligibleVotes;
    mapping(address => bool) public shadow_settled;

    uint256 public shadow_activeBidCount;
    uint256 public shadow_unresolvedCount;
    uint256 public shadow_eligibleCount;

    // ---- Vacuity-check ghost counters (Step 7b, item 1) --------------------------

    /// @dev Reset each run by EVM state revert (invariant runs restart from setUp()).
    mapping(uint256 => bool) public ghost_phaseSeenThisRun;

    uint256 public ghost_commitSuccesses;
    uint256 public ghost_voteSuccesses;
    uint256 public ghost_appealSuccesses;
    uint256 public ghost_revealSuccesses;
    uint256 public ghost_acceptSuccesses;
    uint256 public ghost_settleRefundCount;
    uint256 public ghost_settleForfeitF1Count;
    uint256 public ghost_settleForfeitF2Count;
    uint256 public ghost_settleForfeitF3Count;

    struct ScheduleConfig {
        uint64 submissionDeadline;
        uint64 techRevealEnd;
        uint64 evaluationEnd;
        uint64 appealFilingEnd;
        uint64 priceRevealStart;
        uint64 priceRevealEnd;
        uint64 acceptanceWindow;
        uint8 threshold;
    }

    constructor(
        Tender tender_,
        VendorRegistry registry_,
        MockTLKR token_,
        address pe_,
        address appealsAuthority_,
        address treasury_,
        address[] memory evaluators_,
        address[] memory bidders_,
        uint64[] memory vendorIds_,
        ScheduleConfig memory schedule_
    ) {
        tender = tender_;
        registry = registry_;
        token = token_;
        pe = pe_;
        appealsAuthority = appealsAuthority_;
        treasury = treasury_;
        _evaluators = evaluators_;
        _bidders = bidders_;
        _vendorIds = vendorIds_;

        shadowSubmissionDeadline = schedule_.submissionDeadline;
        shadowTechRevealEnd = schedule_.techRevealEnd;
        shadowEvaluationEnd = schedule_.evaluationEnd;
        shadowAppealFilingEnd = schedule_.appealFilingEnd;
        shadowPriceRevealStart = schedule_.priceRevealStart;
        shadowPriceRevealEnd = schedule_.priceRevealEnd;
        shadowAcceptanceWindow = schedule_.acceptanceWindow;
        shadowThreshold = schedule_.threshold;

        ghost_lastPhaseOrdinal = uint256(tender.currentPhase());
    }

    function bidders() external view returns (address[] memory) {
        return _bidders;
    }

    // ---- Shared bookkeeping -------------------------------------------------

    /// @dev Wraps every action SPEC §4/I10 actually restricts once terminal (commits,
    ///      votes, openings, acceptances, and their supporting actions): checks I6 (phase
    ///      ordinal never decreases) and I10 (none of these succeed once terminal).
    modifier tracked() {
        bool wasTerminalBefore = ghost_wasTerminal;
        uint256 successesBefore = _successCounter;
        _;
        if (wasTerminalBefore && _successCounter > successesBefore) {
            ghost_actionsAfterTerminal++;
        }
        _syncPhase();
    }

    /// @dev For `settle` and `acknowledgeAward`, which are explicitly designed to only
    ///      succeed once the tender is already terminal (that is their correct, intended
    ///      behavior per SPEC §6.9-6.10, not an I10 violation): checks I6 only.
    modifier trackedPostTerminal() {
        _;
        _syncPhase();
    }

    function _syncPhase() internal {
        uint256 ord = uint256(tender.currentPhase());
        assertGe(ord, ghost_lastPhaseOrdinal, "I6: phase ordinal decreased");
        ghost_lastPhaseOrdinal = ord;
        ghost_phaseSeenThisRun[ord] = true;
        ghost_wasTerminal = ord == uint256(Phase.Final) || ord == uint256(Phase.Cancelled)
            || ord == uint256(Phase.Failed);
    }

    uint256 private _successCounter;

    function _markSuccess() internal {
        _successCounter++;
    }

    function _bidder(uint256 seed) internal view returns (address) {
        return _bidders[bound(seed, 0, _bidders.length - 1)];
    }

    function _evaluator(uint256 seed) internal view returns (address) {
        return _evaluators[bound(seed, 0, _evaluators.length - 1)];
    }

    /// @dev Guided targeting (see `_bidderWithState`): prefers an evaluator who hasn't
    ///      voted on `bidder` yet, so k distinct votes actually accumulate instead of
    ///      repeatedly hitting `AlreadyVoted` on the same one or two evaluators.
    function _evaluatorWhoHasntVoted(address bidder, uint256 seed) internal view returns (address) {
        uint256 len = _evaluators.length;
        address[] memory matches = new address[](len);
        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            if (!ghost_votedBefore[_evaluators[i]][bidder]) matches[count++] = _evaluators[i];
        }
        if (count == 0) return _evaluator(seed); // all have voted; harmless AlreadyVoted
        return matches[bound(seed, 0, count - 1)];
    }

    function _vendorIdOf(address bidder) internal view returns (uint64) {
        for (uint256 i = 0; i < _bidders.length; i++) {
            if (_bidders[i] == bidder) return _vendorIds[i];
        }
        return 0;
    }

    /// @dev Picks (via `seed`, when there's a choice) one of the bidders whose SHADOW
    ///      state currently equals `want`, or the zero address if none match. Guided
    ///      targeting: with 5 bidders and ~18 action types, a uniformly random bidder is
    ///      wrong for a given action almost every call, so a whole commit -> reveal ->
    ///      vote -> revealPrice -> accept chain for one bidder essentially never lines up
    ///      within the fuzzer's depth budget. This does not touch *classification*
    ///      (I2 still only trusts the shadow state updated on real successes) -- it only
    ///      chooses a more informative call to attempt next, same as a human tester would.
    function _bidderWithState(BidState want, uint256 seed) internal view returns (address) {
        uint256 len = _bidders.length;
        address[] memory matches = new address[](len);
        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            if (shadow_state[_bidders[i]] == want) matches[count++] = _bidders[i];
        }
        if (count == 0) return address(0);
        return matches[bound(seed, 0, count - 1)];
    }

    /// @dev Like `_bidderWithState(Eligible, ...)`, additionally filtered to bidders that
    ///      haven't opened yet (so `revealPrice` has a real chance to succeed).
    function _unopenedEligibleBidder(uint256 seed) internal view returns (address) {
        uint256 len = _bidders.length;
        address[] memory matches = new address[](len);
        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            address b = _bidders[i];
            if (shadow_state[b] == BidState.Eligible && !shadow_opened[b]) matches[count++] = b;
        }
        if (count == 0) return address(0);
        return matches[bound(seed, 0, count - 1)];
    }

    // ---- Time -------------------------------------------------

    /// @dev Clamps a candidate warp target so it cannot cross `submissionDeadline` while
    ///      there are no active bids, or `priceRevealStart` while there are no eligible
    ///      bids. Both are immediate, absorbing collapses (NoBids / NoEligibleBids) --
    ///      without this guard, an early random warp call reaches them almost every run
    ///      (observed: Cancelled in 98%+ of runs, PriceReveal/Acceptance/Final in 0%),
    ///      burning the rest of that run's depth budget on guaranteed reverts and making
    ///      the late-phase invariants vacuous. This does not prevent those two terminal
    ///      causes from ever being reached -- only from being reached *by a warp that
    ///      still had a real alternative* (e.g. `withdraw`-ing the only bid, or every vote
    ///      genuinely finishing Ineligible, still collapse the tender normally).
    function _clampWarpTarget(uint64 candidate) internal view returns (uint64) {
        if (shadow_activeBidCount == 0 && candidate >= shadowSubmissionDeadline) {
            return shadowSubmissionDeadline == 0 ? 0 : shadowSubmissionDeadline - 1;
        }
        // Once even one bid exists, the guard above stops applying and a single early
        // warp is otherwise free to rush straight past techRevealEnd/evaluationEnd
        // before that bidder ever calls postKeyEnvelope/gets its k-th vote, stranding it
        // (ForfeitedF1, or stuck Revealed/Escalated) and starving every later phase.
        if (_hasBidderInState(BidState.Committed) && candidate >= shadowTechRevealEnd) {
            return shadowTechRevealEnd - 1;
        }
        if (_hasBidderInState(BidState.Revealed) && candidate >= shadowEvaluationEnd) {
            return shadowEvaluationEnd - 1;
        }
        if (shadow_eligibleCount == 0 && candidate >= shadowPriceRevealStart) {
            return shadowPriceRevealStart == 0 ? 0 : shadowPriceRevealStart - 1;
        }
        return candidate;
    }

    function _hasBidderInState(BidState want) internal view returns (bool) {
        for (uint256 i = 0; i < _bidders.length; i++) {
            if (shadow_state[_bidders[i]] == want) return true;
        }
        return false;
    }

    function warp(uint256 seed) external tracked {
        uint256 delta = bound(seed, 0, 3 days);
        uint64 target = _clampWarpTarget(uint64(block.timestamp + delta));
        if (target > uint64(block.timestamp)) vm.warp(target);
    }

    /// @dev Jumps directly to the next schedule boundary (or a small nudge once past all
    ///      of them, to advance offer rounds). Added per Step 7b item 1: pure random
    ///      deltas rarely accumulate enough elapsed time, within the fuzzer's depth
    ///      budget, to reach PriceReveal/Acceptance/Final alongside all the other
    ///      preconditions (reveal, k votes, price reveal) those phases need.
    function warpToNextBoundary(uint256 seed) external tracked {
        uint64 t = uint64(block.timestamp);
        uint64 target;
        if (t < shadowSubmissionDeadline) target = shadowSubmissionDeadline;
        else if (t < shadowTechRevealEnd) target = shadowTechRevealEnd;
        else if (t < shadowEvaluationEnd) target = shadowEvaluationEnd;
        else if (t < shadowAppealFilingEnd) target = shadowAppealFilingEnd;
        else if (t < shadowPriceRevealStart) target = shadowPriceRevealStart;
        else if (t < shadowPriceRevealEnd) target = shadowPriceRevealEnd;
        else target = t + uint64(bound(seed, 0, shadowAcceptanceWindow));

        target = _clampWarpTarget(target);
        if (target > t) vm.warp(target);
    }

    // ---- Bidding (SPEC §6.1-6.3) -------------------------------------------------

    function commit(uint256 bidderSeed, uint256 priceSeed, uint256 docSeed, uint256 saltSeed)
        external
        tracked
    {
        address bidder = _bidderWithState(BidState.None, bidderSeed);
        if (bidder == address(0)) return;
        uint256 price = bound(priceSeed, 1, 1_000_000);
        bytes32 docHash = keccak256(abi.encode("doc", docSeed));
        bytes32 salt = keccak256(abi.encode("salt", saltSeed));
        bytes32 commitment =
            keccak256(abi.encode(block.chainid, address(tender), bidder, price, docHash, salt));

        vm.prank(bidder);
        try tender.commit(commitment, docHash, keccak256("cipher")) {
            ghost_depositsIn += tender.depositAmount();
            ghost_price[bidder] = price;
            ghost_docHash[bidder] = docHash;
            ghost_salt[bidder] = salt;
            ghost_hasCommittedSecret[bidder] = true;
            shadow_state[bidder] = BidState.Committed;
            shadow_activeBidCount++;
            ghost_commitSuccesses++;
            _markSuccess();
        } catch {}
    }

    function replaceCommitment(
        uint256 bidderSeed,
        uint256 priceSeed,
        uint256 docSeed,
        uint256 saltSeed
    ) external tracked {
        address bidder = _bidder(bidderSeed);
        uint256 price = bound(priceSeed, 1, 1_000_000);
        bytes32 docHash = keccak256(abi.encode("doc", docSeed));
        bytes32 salt = keccak256(abi.encode("salt", saltSeed));
        bytes32 commitment =
            keccak256(abi.encode(block.chainid, address(tender), bidder, price, docHash, salt));

        vm.prank(bidder);
        try tender.replaceCommitment(commitment, docHash, keccak256("cipher")) {
            ghost_price[bidder] = price;
            ghost_docHash[bidder] = docHash;
            ghost_salt[bidder] = salt;
            ghost_hasCommittedSecret[bidder] = true;
            _markSuccess();
        } catch {}
    }

    function withdraw(uint256 bidderSeed) external tracked {
        address bidder = _bidderWithState(BidState.Committed, bidderSeed);
        if (bidder == address(0)) return;
        vm.prank(bidder);
        try tender.withdraw() {
            shadow_state[bidder] = BidState.Withdrawn;
            shadow_activeBidCount--;
            _markSuccess();
        } catch {}
    }

    // ---- Technical path (SPEC §6.4-6.6) -------------------------------------------------

    function postKeyEnvelope(uint256 bidderSeed) external tracked {
        address bidder = _bidderWithState(BidState.Committed, bidderSeed);
        if (bidder == address(0)) return;
        vm.prank(bidder);
        try tender.postKeyEnvelope(keccak256(abi.encode("key", bidder))) {
            shadow_state[bidder] = BidState.Revealed;
            shadow_unresolvedCount++;
            _markSuccess();
        } catch {}
    }

    function declareConflict(uint256 evalSeed) external tracked {
        address evaluator = _evaluator(evalSeed);
        vm.prank(evaluator);
        try tender.declareConflict(keccak256("conflict")) {
            _markSuccess();
        } catch {}
    }

    function castVote(uint256 evalSeed, uint256 bidderSeed, bool eligible, uint256 reasonSeed)
        external
        tracked
    {
        address bidder = _bidderWithState(BidState.Revealed, bidderSeed);
        if (bidder == address(0)) return;
        address evaluator = _evaluatorWhoHasntVoted(bidder, evalSeed);
        uint8 reasonCode = eligible ? 1 : uint8(bound(reasonSeed, 2, 8));
        bool alreadyVoted = ghost_votedBefore[evaluator][bidder];

        vm.prank(evaluator);
        try tender.castVote(bidder, eligible, reasonCode, keccak256("report")) {
            if (alreadyVoted) ghost_doubleVoteSuccesses++;
            ghost_votedBefore[evaluator][bidder] = true;
            ghost_voteSuccesses++;

            if (eligible) {
                shadow_eligibleVotes[bidder]++;
                if (shadow_eligibleVotes[bidder] == shadowThreshold) {
                    shadow_state[bidder] = BidState.Eligible;
                    shadow_unresolvedCount--;
                    shadow_eligibleCount++;
                }
            } else {
                shadow_ineligibleVotes[bidder]++;
                if (shadow_ineligibleVotes[bidder] == shadowThreshold) {
                    shadow_state[bidder] = BidState.Ineligible;
                    shadow_unresolvedCount--;
                }
            }
            _markSuccess();
        } catch {}
    }

    function fileAppeal(uint256 bidderSeed) external tracked {
        address bidder = _bidderWithState(BidState.Ineligible, bidderSeed);
        if (bidder == address(0)) return;
        vm.prank(bidder);
        try tender.fileAppeal(keccak256("complaint")) {
            shadow_state[bidder] = BidState.Appealed;
            shadow_unresolvedCount++;
            ghost_appealSuccesses++;
            _markSuccess();
        } catch {}
    }

    function resolveEscalation(uint256 bidderSeed, bool eligible) external tracked {
        address bidder = _bidderWithState(BidState.Revealed, bidderSeed);
        if (bidder == address(0)) return;
        vm.prank(appealsAuthority);
        try tender.resolveEscalation(bidder, eligible, keccak256("reason")) {
            shadow_state[bidder] = eligible ? BidState.Eligible : BidState.Ineligible;
            shadow_unresolvedCount--;
            if (eligible) shadow_eligibleCount++;
            _markSuccess();
        } catch {}
    }

    function resolveAppeal(uint256 bidderSeed, bool upheld) external tracked {
        address bidder = _bidderWithState(BidState.Appealed, bidderSeed);
        if (bidder == address(0)) return;
        vm.prank(appealsAuthority);
        try tender.resolveAppeal(bidder, upheld, keccak256("reason")) {
            shadow_state[bidder] = upheld ? BidState.Eligible : BidState.Ineligible;
            shadow_unresolvedCount--;
            if (upheld) shadow_eligibleCount++;
            _markSuccess();
        } catch {}
    }

    // ---- Cancellation (SPEC §6.7) -------------------------------------------------

    function cancel(uint256 codeSeed) external tracked {
        uint8 code = uint8(bound(codeSeed, 1, 4));
        vm.prank(pe);
        try tender.cancel(code, keccak256("cancel-reason")) {
            ghost_cancelledByPE = true;
            // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
            // forge-lint: disable-next-line(unsafe-typecast)
            ghost_cancelledAt = uint64(block.timestamp);
            _markSuccess();
        } catch {}
    }

    // ---- Price reveal (SPEC §6.8) -------------------------------------------------

    /// @dev Replays the bidder's own last-known committed secret, so this can actually
    ///      succeed once the bid is Eligible and the phase is PriceReveal.
    function revealPrice(uint256 bidderSeed) external tracked {
        address bidder = _unopenedEligibleBidder(bidderSeed);
        if (bidder == address(0)) return;

        try tender.revealPrice(bidder, ghost_price[bidder], ghost_salt[bidder]) {
            shadow_opened[bidder] = true;
            ghost_revealSuccesses++;
            _markSuccess();
        } catch {}
    }

    // ---- Award (SPEC §6.9) -------------------------------------------------

    function acceptAward(uint256 bidderSeed) external tracked {
        // Targeting only: reads the real currentOffer() to find who is actually allowed
        // to accept right now (falls back to a random bidder, which will just revert via
        // try/catch if there's no real offer). This does not weaken I2's independence --
        // it only picks a more informative call to attempt, not how outcomes are judged.
        (uint256 round, address offeree,) = tender.currentOffer();
        address bidder = round > 0 ? offeree : _bidder(bidderSeed);
        vm.prank(bidder);
        try tender.acceptAward() {
            ghost_accepted = true;
            ghost_winner = bidder;
            ghost_acceptSuccesses++;
            _markSuccess();
        } catch {}
    }

    function acknowledgeAward() external trackedPostTerminal {
        vm.prank(pe);
        try tender.acknowledgeAward() {
            _markSuccess();
        } catch {}
    }

    // ---- Settlement (SPEC §6.10) -------------------------------------------------

    function settle(uint256 bidderSeed) external trackedPostTerminal {
        address bidder = _bidder(bidderSeed);
        bool alreadySettled = ghost_settledBefore[bidder];
        // Computed BEFORE calling settle, from the shadow model only (never reads
        // Tender's own derived state) -- see contract-level doc comment for why.
        (Settlement expected, uint8 fCode) = _shadowClassify(bidder);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);
        uint256 bidderBalanceBefore = token.balanceOf(bidder);

        try tender.settle(bidder) {
            if (alreadySettled) ghost_doubleSettleSuccesses++;
            ghost_settledBefore[bidder] = true;
            shadow_settled[bidder] = true;
            uint256 toTreasury = token.balanceOf(treasury) - treasuryBalanceBefore;
            uint256 toBidder = token.balanceOf(bidder) - bidderBalanceBefore;
            ghost_forfeitedOut += toTreasury;
            ghost_refundedOut += toBidder;

            bool realForfeit = toTreasury > 0;
            bool shadowForfeit = expected == Settlement.Forfeit;
            if (realForfeit != shadowForfeit) {
                ghost_forfeitMismatches++;
            } else if (realForfeit) {
                if (fCode == 1) ghost_settleForfeitF1Count++;
                else if (fCode == 2) ghost_settleForfeitF2Count++;
                else if (fCode == 3) ghost_settleForfeitF3Count++;
            } else {
                ghost_settleRefundCount++;
            }
            _markSuccess();
        } catch {}
    }

    /// @dev SPEC §7 F1/F2/F3, but every input is read from this handler's own shadow
    ///      state (built solely from the outcomes of its own successful calls above),
    ///      never from Tender's getBid/currentPhase/terminalCause/ranking/winner. Debarment
    ///      is not modeled because this handler never calls debarVendor, so every shadow
    ///      bidder is vacuously "not debarred" -- matching reality for this action set.
    ///      Returns the outcome and, for a Forfeit, which condition (1=F1, 2=F2, 3=F3).
    function _shadowClassify(address bidder) internal view returns (Settlement, uint8) {
        BidState state = shadow_state[bidder];
        if (state == BidState.None) return (Settlement.None, 0);
        if (shadow_settled[bidder]) return (Settlement.Settled, 0);
        if (state == BidState.Withdrawn) return (Settlement.Refund, 0);

        (Phase phase, TerminalCause cause) = _shadowEvaluate();
        bool terminal = phase == Phase.Final || phase == Phase.Cancelled || phase == Phase.Failed;
        if (!terminal) return (Settlement.Pending, 0);

        if (state == BidState.Committed) {
            bool techRevealPassedBeforeEnd =
                !ghost_cancelledByPE || ghost_cancelledAt >= shadowTechRevealEnd;
            return techRevealPassedBeforeEnd
                ? (Settlement.Forfeit, uint8(1))
                : (Settlement.Refund, uint8(0));
        }

        if (state == BidState.Eligible && !shadow_opened[bidder]) {
            if (
                cause == TerminalCause.NoRankedBids || cause == TerminalCause.AllOffersLapsed
                    || cause == TerminalCause.AwardAccepted
            ) {
                return (Settlement.Forfeit, uint8(2));
            }
        }

        if (state == BidState.Eligible && shadow_opened[bidder]) {
            address[] memory ranked = _shadowRanking();
            uint256 i = _indexOf(ranked, bidder);
            if (i < ranked.length) {
                if (cause == TerminalCause.AllOffersLapsed) return (Settlement.Forfeit, uint8(3));
                if (cause == TerminalCause.AwardAccepted) {
                    uint256 w = _indexOf(ranked, ghost_winner);
                    if (w < ranked.length && w > i) return (Settlement.Forfeit, uint8(3));
                }
            }
        }

        return (Settlement.Refund, 0);
    }

    /// @dev SPEC §4's `_evaluate`, fed entirely by shadow counters (shadow_activeBidCount
    ///      etc.) and this handler's own cancelled/accepted flags -- never by reading
    ///      `tender.currentPhase()`.
    function _shadowEvaluate() internal view returns (Phase, TerminalCause) {
        if (ghost_cancelledByPE) return (Phase.Cancelled, TerminalCause.CancelledByPE);
        if (ghost_accepted) return (Phase.Final, TerminalCause.AwardAccepted);

        uint64 t = uint64(block.timestamp);
        if (t < shadowSubmissionDeadline) return (Phase.Open, TerminalCause.None);
        if (shadow_activeBidCount == 0) return (Phase.Cancelled, TerminalCause.NoBids);
        if (t < shadowTechRevealEnd) return (Phase.TechReveal, TerminalCause.None);
        if (t < shadowEvaluationEnd) return (Phase.Evaluation, TerminalCause.None);
        if (t < shadowAppealFilingEnd) return (Phase.AppealFiling, TerminalCause.None);
        if (t < shadowPriceRevealStart) return (Phase.AppealResolution, TerminalCause.None);
        if (shadow_unresolvedCount > 0) {
            return (Phase.Failed, TerminalCause.UnresolvedAtPriceReveal);
        }
        if (shadow_eligibleCount == 0) return (Phase.Cancelled, TerminalCause.NoEligibleBids);
        if (t < shadowPriceRevealEnd) return (Phase.PriceReveal, TerminalCause.None);

        uint256 r = _shadowRanking().length;
        if (r == 0) return (Phase.Cancelled, TerminalCause.NoRankedBids);
        if (t < shadowPriceRevealEnd + r * shadowAcceptanceWindow) {
            return (Phase.Acceptance, TerminalCause.None);
        }
        return (Phase.Cancelled, TerminalCause.AllOffersLapsed);
    }

    /// @dev SPEC §5 ranking, sorted from shadow-tracked opened prices and each bidder's
    ///      externally-known vendorId -- never by calling `tender.ranking()`.
    function _shadowRanking() internal view returns (address[] memory ranked) {
        uint256 len = _bidders.length;
        address[] memory candidates = new address[](len);
        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            address b = _bidders[i];
            if (shadow_state[b] == BidState.Eligible && shadow_opened[b]) {
                candidates[count++] = b;
            }
        }
        ranked = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            ranked[i] = candidates[i];
        }
        for (uint256 i = 1; i < count; i++) {
            address key = ranked[i];
            uint256 j = i;
            while (j > 0 && _shadowRanksBefore(key, ranked[j - 1])) {
                ranked[j] = ranked[j - 1];
                j--;
            }
            ranked[j] = key;
        }
    }

    function _shadowRanksBefore(address a, address b) internal view returns (bool) {
        if (ghost_price[a] != ghost_price[b]) return ghost_price[a] < ghost_price[b];
        return _shadowTieRank(a) < _shadowTieRank(b);
    }

    function _shadowTieRank(address bidder) internal view returns (bytes32) {
        return keccak256(abi.encode(address(tender), _vendorIdOf(bidder)));
    }

    function _indexOf(address[] memory list, address target) internal pure returns (uint256) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == target) return i;
        }
        return list.length;
    }

    // ---- Direct-transfer surplus (I1: contract must tolerate this) --------------

    /// @dev Deliberately NOT wrapped in `tracked`: this is a plain ERC20 transfer that
    ///      never calls Tender at all, so it cannot move its phase and is not a "Tender
    ///      action" for I10's purposes — SPEC §7 explicitly says surplus direct transfers
    ///      are allowed at any time, including after termination.
    function directTransfer(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 1000);
        if (amount == 0) return;
        vm.prank(pe); // any funded actor; pe never needs its own tokens elsewhere
        try token.transfer(address(tender), amount) {} catch {}
    }
}
