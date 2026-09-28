// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VendorRegistry} from "./VendorRegistry.sol";
import {Bid, BidState, Phase, Settlement, TerminalCause} from "./TenderTypes.sol";

/// @title Tender
/// @notice One sealed-bid public tender: salted price commitments, price-blind k-of-n
///         technical evaluation with bounded escalation and appeals, a contract-computed
///         award, and deposits forfeited only under conditions F1-F3.
/// @dev See docs/SPEC.md (source of truth). Parameters are fixed at creation (I7). The
///      phase is never stored: it is computed on demand by `_evaluate` from the current
///      time and recorded facts (SPEC §4).
contract Tender is ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    address[] internal _bidders;
    mapping(address => Bid) internal _bids;
    // Written by castVote/resolveEscalation/resolveAppeal/cancel/acceptAward (Steps 5-6),
    // not yet implemented, and in the meantime by TenderHarness (test-only); already read
    // by `_evaluate`/`settlementOf` in this step, so forge-lint's uninitialized-state check
    // cannot yet see a writer.
    // forge-lint: disable-next-line(uninitialized-state)
    bool internal _cancelledByPE;
    // forge-lint: disable-next-line(uninitialized-state)
    uint64 internal _cancelledAt;
    // forge-lint: disable-next-line(uninitialized-state)
    bool internal _accepted;
    // forge-lint: disable-next-line(uninitialized-state)
    address internal _winner;
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
    event DepositSettled(
        address indexed bidder, address indexed recipient, uint256 amount, bool forfeited
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

    // ---------------------------------------------------------------------
    // Errors (SPEC §6)
    // ---------------------------------------------------------------------

    error WrongPhase(Phase actual);
    error InvalidBidState(BidState actual);
    error NotRegisteredVendor();
    error RegisteredTooLate(uint64 vendorId);
    error VendorIsDebarred(uint64 vendorId);
    error BidExists();
    error TooManyBidders();
    error NothingToSettle();

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
    // Bidding (SPEC §6.1-6.3)
    // ---------------------------------------------------------------------

    /// @notice Commit a salted price commitment and technical documents, locking a deposit.
    /// @param priceCommitment keccak256(abi.encode(chainid, this, bidder, price, docHash, salt)).
    /// @param docHash Hash of the (encrypted) technical documents.
    /// @param docCipherRef Reference to where the encrypted documents can be fetched.
    function commit(bytes32 priceCommitment, bytes32 docHash, bytes32 docCipherRef)
        external
        nonReentrant
    {
        (Phase phase,) = _evaluate();
        if (phase != Phase.Open) revert WrongPhase(phase);

        uint64 vendorId = registry.vendorIdOf(msg.sender);
        if (vendorId == 0) revert NotRegisteredVendor();
        if (!registry.isRegisteredBefore(vendorId, createdAt)) revert RegisteredTooLate(vendorId);
        if (registry.isDebarred(vendorId)) revert VendorIsDebarred(vendorId);

        if (_bids[msg.sender].state != BidState.None) revert BidExists();
        if (_bidders.length >= maxBidders) revert TooManyBidders();
        if (priceCommitment == bytes32(0) || docHash == bytes32(0) || docCipherRef == bytes32(0)) {
            revert ZeroHash();
        }

        _bids[msg.sender] = Bid({
            vendorId: vendorId,
            state: BidState.Committed,
            priceCommitment: priceCommitment,
            docHash: docHash,
            docCipherRef: docCipherRef,
            keyEnvelopeRef: bytes32(0),
            eligibleVotes: 0,
            ineligibleVotes: 0,
            resolvedByAuthority: false,
            appealed: false,
            opened: false,
            settled: false,
            price: 0
        });
        _bidders.push(msg.sender);
        _activeBidCount++;
        _totalLiabilities += depositAmount;

        token.safeTransferFrom(msg.sender, address(this), depositAmount);

        emit BidCommitted(msg.sender, vendorId, priceCommitment, docHash, docCipherRef);
    }

    /// @notice Replace the caller's price commitment and technical documents. The deposit
    ///         already posted is unaffected.
    function replaceCommitment(bytes32 priceCommitment, bytes32 docHash, bytes32 docCipherRef)
        external
    {
        (Phase phase,) = _evaluate();
        if (phase != Phase.Open) revert WrongPhase(phase);

        Bid storage bid = _bids[msg.sender];
        if (bid.state != BidState.Committed) revert InvalidBidState(bid.state);
        if (priceCommitment == bytes32(0) || docHash == bytes32(0) || docCipherRef == bytes32(0)) {
            revert ZeroHash();
        }

        bid.priceCommitment = priceCommitment;
        bid.docHash = docHash;
        bid.docCipherRef = docCipherRef;

        emit CommitmentReplaced(msg.sender, priceCommitment, docHash, docCipherRef);
    }

    /// @notice Withdraw the caller's bid. The deposit becomes immediately refundable
    ///         (see `settlementOf`, SPEC §7).
    function withdraw() external {
        (Phase phase,) = _evaluate();
        if (phase != Phase.Open) revert WrongPhase(phase);

        Bid storage bid = _bids[msg.sender];
        if (bid.state != BidState.Committed) revert InvalidBidState(bid.state);

        bid.state = BidState.Withdrawn;
        _activeBidCount--;

        emit BidWithdrawn(msg.sender);
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

    /// @notice Number of bids that would count toward ranking (SPEC §5). See `ranking`.
    function rankedCount() public view returns (uint256) {
        return ranking().length;
    }

    // ---------------------------------------------------------------------
    // Ranking and offer rounds (SPEC §5)
    // ---------------------------------------------------------------------

    /// @notice Ranked bidders sorted by price ascending, tie rank ascending. A ranked bid
    ///         has state Eligible, is opened, and is not debarred strictly before
    ///         `priceRevealStart`.
    /// @dev Bounded by `maxBidders` (<= 50); insertion sort.
    function ranking() public view returns (address[] memory ranked) {
        uint256 len = _bidders.length;
        address[] memory candidates = new address[](len);
        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            address bidder = _bidders[i];
            Bid storage b = _bids[bidder];
            if (b.state == BidState.Eligible && b.opened) {
                // The registry is the only external contract this view may call (besides
                // the deposit token, unused here); the loop is bounded by maxBidders (<= 50).
                // forge-lint: disable-next-line(calls-loop)
                bool debarredBeforeCutoff = registry.isDebarredBefore(b.vendorId, priceRevealStart);
                if (!debarredBeforeCutoff) {
                    candidates[count] = bidder;
                    count++;
                }
            }
        }

        ranked = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            ranked[i] = candidates[i];
        }
        for (uint256 i = 1; i < count; i++) {
            address key = ranked[i];
            uint256 j = i;
            while (j > 0 && _ranksBefore(key, ranked[j - 1])) {
                ranked[j] = ranked[j - 1];
                j--;
            }
            ranked[j] = key;
        }
    }

    /// @notice The current offer round, if any (SPEC §5). `round` is 1-based; 0 if none.
    function currentOffer()
        external
        view
        returns (uint256 round, address offeree, uint64 windowEnd)
    {
        // casting to uint64 is safe: block timestamps fit in uint64 for ~584 billion years
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 t = uint64(block.timestamp);
        if (t < priceRevealEnd) return (0, address(0), 0);

        uint64 i = (t - priceRevealEnd) / acceptanceWindow;
        address[] memory ranked = ranking();
        if (i >= ranked.length) return (0, address(0), 0);

        round = i + 1;
        offeree = ranked[i];
        windowEnd = priceRevealEnd + (i + 1) * acceptanceWindow;
    }

    /// @dev Deterministic, arbitrary tie-break: lower hash wins (SPEC §5).
    function _tieRank(uint64 vendorId) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), vendorId));
    }

    /// @dev True if bid `a` ranks strictly before bid `b`: lower price, then lower tie rank.
    function _ranksBefore(address a, address b) internal view returns (bool) {
        Bid storage bidA = _bids[a];
        Bid storage bidB = _bids[b];
        if (bidA.price != bidB.price) return bidA.price < bidB.price;
        return _tieRank(bidA.vendorId) < _tieRank(bidB.vendorId);
    }

    /// @dev Linear search bounded by `maxBidders` (<= 50). Returns `list.length` (an
    ///      otherwise-invalid index) as the not-found sentinel.
    function _indexOf(address[] memory list, address target) internal pure returns (uint256 index) {
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == target) return i;
        }
        return len;
    }

    // ---------------------------------------------------------------------
    // Settlement (SPEC §6.10, §7)
    // ---------------------------------------------------------------------

    /// @notice The settlement outcome for `bidder`'s deposit: a pure function of the bid's
    ///         final status and the tender's terminal state (SPEC §7).
    function settlementOf(address bidder)
        public
        view
        returns (Settlement outcome, address recipient, uint256 amount)
    {
        Bid storage bid = _bids[bidder];
        if (bid.state == BidState.None) return (Settlement.None, address(0), 0);
        if (bid.settled) return (Settlement.Settled, address(0), 0);
        if (bid.state == BidState.Withdrawn) return (Settlement.Refund, bidder, depositAmount);

        (Phase phase, TerminalCause cause) = _evaluate();
        if (phase != Phase.Final && phase != Phase.Cancelled && phase != Phase.Failed) {
            return (Settlement.Pending, address(0), 0);
        }

        // F1: committed but never posted a key envelope, and the tech-reveal deadline
        // passed before the tender ended.
        if (bid.state == BidState.Committed) {
            bool techRevealPassedBeforeEnd = !_cancelledByPE || _cancelledAt >= techRevealEnd;
            if (techRevealPassedBeforeEnd) return (Settlement.Forfeit, treasury, depositAmount);
            return (Settlement.Refund, bidder, depositAmount);
        }

        bool debarredBeforeCutoff = registry.isDebarredBefore(bid.vendorId, priceRevealStart);

        // F2: eligible but never opened (withheld its price), and the price-reveal phase
        // completed.
        if (bid.state == BidState.Eligible && !bid.opened && !debarredBeforeCutoff) {
            if (
                cause == TerminalCause.NoRankedBids || cause == TerminalCause.AllOffersLapsed
                    || cause == TerminalCause.AwardAccepted
            ) {
                return (Settlement.Forfeit, treasury, depositAmount);
            }
        }

        // F3: ranked, but its offer window passed without acceptance.
        if (bid.state == BidState.Eligible && bid.opened && !debarredBeforeCutoff) {
            address[] memory ranked = ranking();
            uint256 i = _indexOf(ranked, bidder);
            if (i < ranked.length) {
                if (cause == TerminalCause.AllOffersLapsed) {
                    return (Settlement.Forfeit, treasury, depositAmount);
                }
                if (cause == TerminalCause.AwardAccepted) {
                    uint256 w = _indexOf(ranked, _winner);
                    if (w < ranked.length && w > i) {
                        return (Settlement.Forfeit, treasury, depositAmount);
                    }
                }
            }
        }

        return (Settlement.Refund, bidder, depositAmount);
    }

    /// @notice Settle `bidder`'s deposit: pays out a Refund or Forfeit exactly once (I11).
    ///         Callable by anyone.
    function settle(address bidder) external nonReentrant {
        (Settlement outcome, address recipient, uint256 amount) = settlementOf(bidder);
        if (outcome != Settlement.Refund && outcome != Settlement.Forfeit) {
            revert NothingToSettle();
        }

        _bids[bidder].settled = true;
        _totalLiabilities -= amount;

        token.safeTransfer(recipient, amount);

        emit DepositSettled(bidder, recipient, amount, outcome == Settlement.Forfeit);
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

    /// @notice Total deposit liabilities the contract currently owes bidders (I1).
    function totalLiabilities() external view returns (uint256) {
        return _totalLiabilities;
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
