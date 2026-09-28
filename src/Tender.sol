// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VendorRegistry} from "./VendorRegistry.sol";
import {Bid, BidState, Phase, TerminalCause} from "./TenderTypes.sol";

/// @title Tender
/// @notice One sealed-bid public tender: salted price commitments, price-blind k-of-n
///         technical evaluation with bounded escalation and appeals, a contract-computed
///         award, and deposits forfeited only under conditions F1-F3.
/// @dev See docs/SPEC.md (source of truth). Parameters are fixed at creation (I7). The
///      phase is never stored: it is computed on demand by `_evaluate` from the current
///      time and recorded facts (SPEC §4).
contract Tender {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint64 private constant MIN_WINDOW = 60;
    uint256 private constant MAX_BIDDERS_CAP = 50;
    uint256 private constant MAX_EVALUATORS = 15;
    uint256 private constant ENC_KEY_LENGTH = 33;

    // ---------------------------------------------------------------------
    // Configuration types (SPEC §3)
    // ---------------------------------------------------------------------

    /// @dev Timestamps, except `acceptanceWindow` which is a duration in seconds.
    struct Schedule {
        uint64 submissionDeadline;
        uint64 techRevealEnd;
        uint64 evaluationEnd;
        uint64 appealFilingEnd;
        uint64 priceRevealStart;
        uint64 priceRevealEnd;
        uint64 acceptanceWindow;
    }

    struct TenderConfig {
        address registry;
        address token;
        address pe;
        address appealsAuthority;
        address treasury;
        address[] evaluators;
        bytes[] evaluatorEncKeys;
        uint8 threshold;
        uint256 depositAmount;
        uint256 maxBidders;
        bytes32 biddingDocsHash;
        Schedule schedule;
    }

    // ---------------------------------------------------------------------
    // Immutable parameters (I7)
    // ---------------------------------------------------------------------

    VendorRegistry public immutable registry;
    IERC20 public immutable token;
    address public immutable pe;
    address public immutable appealsAuthority;
    address public immutable treasury;
    uint8 public immutable threshold;
    uint256 public immutable depositAmount;
    uint256 public immutable maxBidders;
    bytes32 public immutable biddingDocsHash;

    uint64 public immutable submissionDeadline;
    uint64 public immutable techRevealEnd;
    uint64 public immutable evaluationEnd;
    uint64 public immutable appealFilingEnd;
    uint64 public immutable priceRevealStart;
    uint64 public immutable priceRevealEnd;
    uint64 public immutable acceptanceWindow;

    /// @dev Registration cutoff for vendors (I8).
    uint64 public immutable createdAt;

    /// @dev Written only in the constructor (I7); not `immutable` because Solidity does
    ///      not allow immutable dynamic arrays.
    address[] private _evaluators;
    bytes[] private _evaluatorEncKeys;
    mapping(address => bool) public isEvaluator;

    // ---------------------------------------------------------------------
    // Recorded facts (SPEC §4) — the only mutable state besides the fields above.
    // `internal` (not `private`) so the test-only TenderHarness can set them directly.
    // ---------------------------------------------------------------------

    // These are written by Step 3-6 functions (commit, castVote, resolveAppeal, ...) not
    // yet implemented, and in the meantime by TenderHarness (test-only); already read by
    // `_evaluate`/`rankedCount` in this step, so forge-lint's uninitialized-state check
    // cannot yet see a writer.
    // forge-lint: disable-next-line(uninitialized-state)
    address[] internal _bidders;
    mapping(address => Bid) internal _bids;
    // forge-lint: disable-next-line(uninitialized-state)
    bool internal _cancelledByPE;
    uint64 internal _cancelledAt;
    // forge-lint: disable-next-line(uninitialized-state)
    bool internal _accepted;
    address internal _winner;
    // forge-lint: disable-next-line(uninitialized-state)
    uint256 internal _activeBidCount;
    // forge-lint: disable-next-line(uninitialized-state)
    uint256 internal _unresolvedCount;
    // forge-lint: disable-next-line(uninitialized-state)
    uint256 internal _eligibleCount;
    uint256 internal _totalLiabilities;
    /// @dev _hasVoted[bidder][evaluator]
    mapping(address => mapping(address => bool)) internal _hasVoted;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event TenderCreated(
        address registry,
        address token,
        address pe,
        address appealsAuthority,
        address treasury,
        address[] evaluators,
        bytes[] evaluatorEncKeys,
        uint8 threshold,
        uint256 depositAmount,
        uint256 maxBidders,
        bytes32 biddingDocsHash,
        Schedule schedule,
        uint64 createdAt
    );

    // ---------------------------------------------------------------------
    // Errors (SPEC §3)
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error ZeroHash();
    error RoleConflict(address account);
    error InvalidEvaluatorCount(uint256 n);
    error InvalidThreshold(uint8 k, uint256 n);
    error EncKeyCountMismatch(uint256 got, uint256 expected);
    error InvalidEncKey(uint256 index);
    error DuplicateEvaluator(address evaluator);
    error InvalidDeposit();
    error InvalidMaxBidders(uint256 maxBidders);
    error InvalidSchedule(uint8 check);

    /// @notice Deploy one tender. Every parameter is fixed for its lifetime (I7).
    /// @param config Full tender configuration (SPEC §3). Reverts on any validation failure.
    constructor(TenderConfig memory config) {
        if (
            config.registry == address(0) || config.token == address(0) || config.pe == address(0)
                || config.appealsAuthority == address(0) || config.treasury == address(0)
        ) revert ZeroAddress();
        if (config.pe == config.appealsAuthority) revert RoleConflict(config.pe);

        uint256 n = config.evaluators.length;
        if (n == 0 || n > MAX_EVALUATORS) revert InvalidEvaluatorCount(n);
        if (
            config.threshold == 0 || uint256(config.threshold) > n
                || 2 * uint256(config.threshold) <= n
        ) {
            revert InvalidThreshold(config.threshold, n);
        }

        if (config.evaluatorEncKeys.length != n) {
            revert EncKeyCountMismatch(config.evaluatorEncKeys.length, n);
        }
        // Reverting per-element is intentional here: n is bounded by MAX_EVALUATORS (15),
        // so this can never be a gas/DoS concern, and the exact bad index/address is
        // valuable in the revert reason.
        for (uint256 i = 0; i < n; i++) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (config.evaluatorEncKeys[i].length != ENC_KEY_LENGTH) revert InvalidEncKey(i);
        }

        for (uint256 i = 0; i < n; i++) {
            address evaluator = config.evaluators[i];
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (evaluator == address(0)) revert ZeroAddress();
            if (evaluator == config.pe || evaluator == config.appealsAuthority) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert RoleConflict(evaluator);
            }
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (isEvaluator[evaluator]) revert DuplicateEvaluator(evaluator);
            isEvaluator[evaluator] = true;
            _evaluators.push(evaluator);
            _evaluatorEncKeys.push(config.evaluatorEncKeys[i]);
        }

        if (config.depositAmount == 0) revert InvalidDeposit();
        if (config.maxBidders == 0 || config.maxBidders > MAX_BIDDERS_CAP) {
            revert InvalidMaxBidders(config.maxBidders);
        }
        if (config.biddingDocsHash == bytes32(0)) revert ZeroHash();

        Schedule memory s = config.schedule;

        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);

        if (s.submissionDeadline < nowTs + MIN_WINDOW) revert InvalidSchedule(1);
        if (s.techRevealEnd < s.submissionDeadline + MIN_WINDOW) revert InvalidSchedule(2);
        if (s.evaluationEnd < s.techRevealEnd + MIN_WINDOW) revert InvalidSchedule(3);
        if (s.appealFilingEnd < s.evaluationEnd + MIN_WINDOW) revert InvalidSchedule(4);
        if (s.priceRevealStart < s.appealFilingEnd + MIN_WINDOW) revert InvalidSchedule(5);
        if (s.priceRevealEnd < s.priceRevealStart + MIN_WINDOW) revert InvalidSchedule(6);
        if (s.acceptanceWindow < MIN_WINDOW) revert InvalidSchedule(7);

        registry = VendorRegistry(config.registry);
        token = IERC20(config.token);
        pe = config.pe;
        appealsAuthority = config.appealsAuthority;
        treasury = config.treasury;
        threshold = config.threshold;
        depositAmount = config.depositAmount;
        maxBidders = config.maxBidders;
        biddingDocsHash = config.biddingDocsHash;

        submissionDeadline = s.submissionDeadline;
        techRevealEnd = s.techRevealEnd;
        evaluationEnd = s.evaluationEnd;
        appealFilingEnd = s.appealFilingEnd;
        priceRevealStart = s.priceRevealStart;
        priceRevealEnd = s.priceRevealEnd;
        acceptanceWindow = s.acceptanceWindow;

        createdAt = nowTs;

        emit TenderCreated(
            config.registry,
            config.token,
            config.pe,
            config.appealsAuthority,
            config.treasury,
            config.evaluators,
            config.evaluatorEncKeys,
            config.threshold,
            config.depositAmount,
            config.maxBidders,
            config.biddingDocsHash,
            s,
            nowTs
        );
    }

    // ---------------------------------------------------------------------
    // Phase (SPEC §4) — never stored, always derived
    // ---------------------------------------------------------------------

    /// @notice The tender's current phase, derived from time and recorded facts.
    function currentPhase() external view returns (Phase phase) {
        (phase,) = _evaluate();
    }

    /// @notice The terminal cause, or `None` while the tender is not yet terminal.
    function terminalCause() external view returns (TerminalCause cause) {
        (, cause) = _evaluate();
    }

    /// @dev Single source of truth for phase and terminal cause (SPEC §4). Nothing
    ///      "advances" phases; this is a pure function of time and recorded facts.
    function _evaluate() internal view returns (Phase, TerminalCause) {
        if (_cancelledByPE) return (Phase.Cancelled, TerminalCause.CancelledByPE);
        if (_accepted) return (Phase.Final, TerminalCause.AwardAccepted);

        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 t = uint64(block.timestamp);

        if (t < submissionDeadline) return (Phase.Open, TerminalCause.None);
        if (_activeBidCount == 0) return (Phase.Cancelled, TerminalCause.NoBids);
        if (t < techRevealEnd) return (Phase.TechReveal, TerminalCause.None);
        if (t < evaluationEnd) return (Phase.Evaluation, TerminalCause.None);
        if (t < appealFilingEnd) return (Phase.AppealFiling, TerminalCause.None);
        if (t < priceRevealStart) return (Phase.AppealResolution, TerminalCause.None);
        if (_unresolvedCount > 0) return (Phase.Failed, TerminalCause.UnresolvedAtPriceReveal);
        if (_eligibleCount == 0) return (Phase.Cancelled, TerminalCause.NoEligibleBids);
        if (t < priceRevealEnd) return (Phase.PriceReveal, TerminalCause.None);

        uint256 r = rankedCount();
        if (r == 0) return (Phase.Cancelled, TerminalCause.NoRankedBids);
        if (t < priceRevealEnd + r * acceptanceWindow) {
            return (Phase.Acceptance, TerminalCause.None);
        }
        return (Phase.Cancelled, TerminalCause.AllOffersLapsed);
    }

    /// @notice Number of bids that would count toward ranking (SPEC §5): state Eligible,
    ///         opened, and not debarred strictly before `priceRevealStart`.
    /// @dev Bounded by `maxBidders` (<= 50).
    function rankedCount() public view returns (uint256 count) {
        uint256 len = _bidders.length;
        for (uint256 i = 0; i < len; i++) {
            Bid storage b = _bids[_bidders[i]];
            if (b.state == BidState.Eligible && b.opened) {
                // The registry is the only external contract this view may call (besides
                // the deposit token, unused here); the loop is bounded by maxBidders (<= 50).
                // forge-lint: disable-next-line(calls-loop)
                bool debarredBeforeCutoff = registry.isDebarredBefore(b.vendorId, priceRevealStart);
                if (!debarredBeforeCutoff) count++;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Full bid record for `bidder` (zero-valued, state `None`, if none exists).
    function getBid(address bidder) external view returns (Bid memory) {
        return _bids[bidder];
    }

    /// @notice Addresses that have ever committed a bid, in commit order.
    function bidders() external view returns (address[] memory) {
        return _bidders;
    }

    /// @notice The fixed evaluator set, in constructor order.
    function evaluators() external view returns (address[] memory) {
        return _evaluators;
    }

    /// @notice Each evaluator's encryption public key, same order as `evaluators()`.
    function evaluatorEncKeys() external view returns (bytes[] memory) {
        return _evaluatorEncKeys;
    }

    /// @notice Number of evaluators (n).
    function evaluatorCount() external view returns (uint256) {
        return _evaluators.length;
    }

    /// @notice The tender's fixed schedule.
    function schedule() external view returns (Schedule memory) {
        return Schedule({
            submissionDeadline: submissionDeadline,
            techRevealEnd: techRevealEnd,
            evaluationEnd: evaluationEnd,
            appealFilingEnd: appealFilingEnd,
            priceRevealStart: priceRevealStart,
            priceRevealEnd: priceRevealEnd,
            acceptanceWindow: acceptanceWindow
        });
    }
}
