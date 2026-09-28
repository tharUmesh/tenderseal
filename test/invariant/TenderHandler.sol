// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tender} from "../../src/Tender.sol";
import {VendorRegistry} from "../../src/VendorRegistry.sol";
import {MockTLKR} from "../../src/MockTLKR.sol";
import {Bid, BidState, Phase, Settlement, TerminalCause} from "../../src/TenderTypes.sol";

/// @dev Bounded invariant handler: a fixed cast of actors (bidders, the tender's own
///      evaluators/PE/authority) drive every state-changing Tender function through
///      try/catch, so illegal calls are simply skipped rather than failing the run
///      (`fail_on_revert = false`). Time only ever moves forward, by a bounded amount.
///      Ghost variables let the invariant test check facts the contract itself does not
///      expose as a single view (an independent deposit ledger, phase-ordinal history,
///      per-bidder committed secrets so `revealPrice` can sometimes actually succeed).
contract TenderHandler is Test {
    Tender public immutable tender;
    VendorRegistry public immutable registry;
    MockTLKR public immutable token;
    address public immutable pe;
    address public immutable appealsAuthority;
    address public immutable treasury;

    address[] internal _evaluators;
    address[] internal _bidders;
    uint64[] internal _vendorIds;

    // ---- Ghost state -------------------------------------------------

    uint256 public ghost_depositsIn;
    uint256 public ghost_refundedOut;
    uint256 public ghost_forfeitedOut;
    uint256 public ghost_lastPhaseOrdinal;
    bool public ghost_wasTerminal;
    uint256 public ghost_actionsAfterTerminal;
    uint256 public ghost_doubleSettleSuccesses;
    uint256 public ghost_doubleVoteSuccesses;
    uint256 public ghost_forfeitMismatches;
    bool public ghost_cancelledByPE;
    uint64 public ghost_cancelledAt;

    mapping(address => bool) public ghost_hasCommittedSecret;
    mapping(address => uint256) public ghost_price;
    mapping(address => bytes32) public ghost_docHash;
    mapping(address => bytes32) public ghost_salt;
    mapping(address => bool) public ghost_settledBefore;
    mapping(address => mapping(address => bool)) public ghost_votedBefore; // [evaluator][bidder]

    constructor(
        Tender tender_,
        VendorRegistry registry_,
        MockTLKR token_,
        address pe_,
        address appealsAuthority_,
        address treasury_,
        address[] memory evaluators_,
        address[] memory bidders_,
        uint64[] memory vendorIds_
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

    function _vendorIdOf(address bidder) internal view returns (uint64) {
        for (uint256 i = 0; i < _bidders.length; i++) {
            if (_bidders[i] == bidder) return _vendorIds[i];
        }
        return 0;
    }

    // ---- Time -------------------------------------------------

    function warp(uint256 seed) external tracked {
        uint256 delta = bound(seed, 0, 3 days);
        vm.warp(block.timestamp + delta);
    }

    // ---- Bidding (SPEC §6.1-6.3) -------------------------------------------------

    function commit(uint256 bidderSeed, uint256 priceSeed, uint256 docSeed, uint256 saltSeed)
        external
        tracked
    {
        address bidder = _bidder(bidderSeed);
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
        address bidder = _bidder(bidderSeed);
        vm.prank(bidder);
        try tender.withdraw() {
            _markSuccess();
        } catch {}
    }

    // ---- Technical path (SPEC §6.4-6.6) -------------------------------------------------

    function postKeyEnvelope(uint256 bidderSeed) external tracked {
        address bidder = _bidder(bidderSeed);
        vm.prank(bidder);
        try tender.postKeyEnvelope(keccak256(abi.encode("key", bidder))) {
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
        address evaluator = _evaluator(evalSeed);
        address bidder = _bidder(bidderSeed);
        uint8 reasonCode = eligible ? 1 : uint8(bound(reasonSeed, 2, 8));
        bool alreadyVoted = ghost_votedBefore[evaluator][bidder];

        vm.prank(evaluator);
        try tender.castVote(bidder, eligible, reasonCode, keccak256("report")) {
            if (alreadyVoted) ghost_doubleVoteSuccesses++;
            ghost_votedBefore[evaluator][bidder] = true;
            _markSuccess();
        } catch {}
    }

    function fileAppeal(uint256 bidderSeed) external tracked {
        address bidder = _bidder(bidderSeed);
        vm.prank(bidder);
        try tender.fileAppeal(keccak256("complaint")) {
            _markSuccess();
        } catch {}
    }

    function resolveEscalation(uint256 bidderSeed, bool eligible) external tracked {
        address bidder = _bidder(bidderSeed);
        vm.prank(appealsAuthority);
        try tender.resolveEscalation(bidder, eligible, keccak256("reason")) {
            _markSuccess();
        } catch {}
    }

    function resolveAppeal(uint256 bidderSeed, bool upheld) external tracked {
        address bidder = _bidder(bidderSeed);
        vm.prank(appealsAuthority);
        try tender.resolveAppeal(bidder, upheld, keccak256("reason")) {
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
        address bidder = _bidder(bidderSeed);
        if (!ghost_hasCommittedSecret[bidder]) return;

        try tender.revealPrice(bidder, ghost_price[bidder], ghost_salt[bidder]) {
            _markSuccess();
        } catch {}
    }

    // ---- Award (SPEC §6.9) -------------------------------------------------

    function acceptAward(uint256 bidderSeed) external tracked {
        address bidder = _bidder(bidderSeed);
        vm.prank(bidder);
        try tender.acceptAward() {
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
        // Computed from pre-settlement state (matching what settlementOf sees), using an
        // independent re-derivation of SPEC §7's F1/F2/F3 (I2).
        bool expectedForfeit = _shadowIsForfeit(bidder);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);
        uint256 bidderBalanceBefore = token.balanceOf(bidder);

        try tender.settle(bidder) {
            if (alreadySettled) ghost_doubleSettleSuccesses++;
            ghost_settledBefore[bidder] = true;
            uint256 toTreasury = token.balanceOf(treasury) - treasuryBalanceBefore;
            uint256 toBidder = token.balanceOf(bidder) - bidderBalanceBefore;
            ghost_forfeitedOut += toTreasury;
            ghost_refundedOut += toBidder;
            if ((toTreasury > 0) != expectedForfeit) ghost_forfeitMismatches++;
            _markSuccess();
        } catch {}
    }

    /// @dev Independent re-derivation of SPEC §7 F1/F2/F3, using only public getters and
    ///      the handler's own ghost-tracked cancellation facts (the only recorded fact
    ///      Tender does not expose via a view). Used to cross-check `settle`'s real
    ///      outcome for I2, not to replace it.
    function _shadowIsForfeit(address bidder) internal view returns (bool) {
        Bid memory bid = tender.getBid(bidder);
        if (bid.state == BidState.None || bid.settled || bid.state == BidState.Withdrawn) {
            return false;
        }

        Phase phase = tender.currentPhase();
        bool terminal = phase == Phase.Final || phase == Phase.Cancelled || phase == Phase.Failed;
        if (!terminal) return false;

        if (bid.state == BidState.Committed) {
            bool techRevealPassedBeforeEnd =
                !ghost_cancelledByPE || ghost_cancelledAt >= tender.techRevealEnd();
            return techRevealPassedBeforeEnd; // F1
        }

        bool debarredBeforeCutoff =
            registry.isDebarredBefore(bid.vendorId, tender.priceRevealStart());
        TerminalCause cause = tender.terminalCause();

        if (bid.state == BidState.Eligible && !bid.opened && !debarredBeforeCutoff) {
            if (
                cause == TerminalCause.NoRankedBids || cause == TerminalCause.AllOffersLapsed
                    || cause == TerminalCause.AwardAccepted
            ) {
                return true; // F2
            }
        }

        if (bid.state == BidState.Eligible && bid.opened && !debarredBeforeCutoff) {
            address[] memory ranked = tender.ranking();
            uint256 i = _indexOf(ranked, bidder);
            if (i < ranked.length) {
                if (cause == TerminalCause.AllOffersLapsed) return true; // F3
                if (cause == TerminalCause.AwardAccepted) {
                    uint256 w = _indexOf(ranked, tender.winner());
                    if (w < ranked.length && w > i) return true; // F3
                }
            }
        }

        return false;
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
