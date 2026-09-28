// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Tender} from "../src/Tender.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev Constructor / configuration validation tests (SPEC §3).
contract TenderTest is TenderTestBase {
    uint64 internal constant MIN_WINDOW = 60;

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
        Tender.Schedule schedule,
        uint64 createdAt
    );

    // ------------------------------------------------------------------ helpers

    function _minSchedule() internal pure returns (Tender.Schedule memory s) {
        s.submissionDeadline = T0 + MIN_WINDOW;
        s.techRevealEnd = s.submissionDeadline + MIN_WINDOW;
        s.evaluationEnd = s.techRevealEnd + MIN_WINDOW;
        s.appealFilingEnd = s.evaluationEnd + MIN_WINDOW;
        s.priceRevealStart = s.appealFilingEnd + MIN_WINDOW;
        s.priceRevealEnd = s.priceRevealStart + MIN_WINDOW;
        s.acceptanceWindow = MIN_WINDOW;
    }

    function _configWithNK(uint256 n, uint8 k)
        internal
        view
        returns (Tender.TenderConfig memory config)
    {
        config = _defaultConfig();
        address[] memory evals = new address[](n);
        bytes[] memory keys = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            evals[i] = vm.addr(i + 1000);
            keys[i] = _encKey(i + 1000);
        }
        config.evaluators = evals;
        config.evaluatorEncKeys = keys;
        config.threshold = k;
    }

    // ------------------------------------------------------------------ happy path

    function test_Constructor_StoresConfigAndEmits() public {
        Tender.TenderConfig memory config = _defaultConfig();

        vm.expectEmit(false, false, false, true);
        emit TenderCreated(
            address(registry),
            address(token),
            pe,
            appealsAuthority,
            treasury,
            config.evaluators,
            config.evaluatorEncKeys,
            2,
            DEPOSIT,
            20,
            DOCS_HASH,
            _defaultSchedule(),
            T0
        );
        Tender t = new Tender(config);

        assertEq(address(t.registry()), address(registry));
        assertEq(address(t.token()), address(token));
        assertEq(t.pe(), pe);
        assertEq(t.appealsAuthority(), appealsAuthority);
        assertEq(t.treasury(), treasury);
        assertEq(t.threshold(), 2);
        assertEq(t.depositAmount(), DEPOSIT);
        assertEq(t.maxBidders(), 20);
        assertEq(t.biddingDocsHash(), DOCS_HASH);
        assertEq(t.createdAt(), T0);

        assertEq(t.submissionDeadline(), T0 + 1 days);
        assertEq(t.techRevealEnd(), T0 + 2 days);
        assertEq(t.evaluationEnd(), T0 + 4 days);
        assertEq(t.appealFilingEnd(), T0 + 5 days);
        assertEq(t.priceRevealStart(), T0 + 7 days);
        assertEq(t.priceRevealEnd(), T0 + 8 days);
        assertEq(t.acceptanceWindow(), 1 days);

        address[] memory evals = t.evaluators();
        assertEq(evals.length, 3);
        assertEq(evals[0], eval1);
        assertEq(evals[1], eval2);
        assertEq(evals[2], eval3);
        assertTrue(t.isEvaluator(eval1));
        assertTrue(t.isEvaluator(eval2));
        assertTrue(t.isEvaluator(eval3));
        assertFalse(t.isEvaluator(pe));
        assertEq(t.evaluatorCount(), 3);

        bytes[] memory keys = t.evaluatorEncKeys();
        assertEq(keys.length, 3);
        assertEq(keys[0], _encKey(1));

        assertEq(t.bidders().length, 0);
        assertEq(uint256(t.getBid(eval1).state), uint256(0)); // BidState.None
    }

    function test_Schedule_ReturnsFullStructMatchingImmutables() public {
        Tender t = new Tender(_defaultConfig());
        Tender.Schedule memory s = t.schedule();

        assertEq(s.submissionDeadline, t.submissionDeadline());
        assertEq(s.techRevealEnd, t.techRevealEnd());
        assertEq(s.evaluationEnd, t.evaluationEnd());
        assertEq(s.appealFilingEnd, t.appealFilingEnd());
        assertEq(s.priceRevealStart, t.priceRevealStart());
        assertEq(s.priceRevealEnd, t.priceRevealEnd());
        assertEq(s.acceptanceWindow, t.acceptanceWindow());
    }

    function test_Constructor_AcceptsExactMinimumWindows() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.schedule = _minSchedule();
        Tender t = new Tender(config);
        assertEq(t.submissionDeadline(), T0 + MIN_WINDOW);
        assertEq(t.acceptanceWindow(), MIN_WINDOW);
    }

    // ------------------------------------------------------------------ zero addresses

    function test_Constructor_RevertsOnZeroRegistry() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.registry = address(0);
        vm.expectRevert(Tender.ZeroAddress.selector);
        new Tender(config);
    }

    function test_Constructor_RevertsOnZeroToken() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.token = address(0);
        vm.expectRevert(Tender.ZeroAddress.selector);
        new Tender(config);
    }

    function test_Constructor_RevertsOnZeroPE() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.pe = address(0);
        vm.expectRevert(Tender.ZeroAddress.selector);
        new Tender(config);
    }

    function test_Constructor_RevertsOnZeroAppealsAuthority() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.appealsAuthority = address(0);
        vm.expectRevert(Tender.ZeroAddress.selector);
        new Tender(config);
    }

    function test_Constructor_RevertsOnZeroTreasury() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.treasury = address(0);
        vm.expectRevert(Tender.ZeroAddress.selector);
        new Tender(config);
    }

    // ------------------------------------------------------------------ role conflict

    function test_Constructor_RevertsWhenPeEqualsAppealsAuthority() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.appealsAuthority = pe;
        vm.expectRevert(abi.encodeWithSelector(Tender.RoleConflict.selector, pe));
        new Tender(config);
    }

    // ------------------------------------------------------------------ evaluator count

    function test_Constructor_RevertsOnZeroEvaluators() public {
        Tender.TenderConfig memory config = _configWithNK(0, 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidEvaluatorCount.selector, 0));
        new Tender(config);
    }

    function test_Constructor_RevertsOnTooManyEvaluators() public {
        Tender.TenderConfig memory config = _configWithNK(16, 9);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidEvaluatorCount.selector, 16));
        new Tender(config);
    }

    // ------------------------------------------------------------------ threshold matrix

    function test_Constructor_AcceptsValidThresholds() public {
        new Tender(_configWithNK(1, 1));
        new Tender(_configWithNK(3, 2));
        new Tender(_configWithNK(3, 3));
        new Tender(_configWithNK(5, 3));
    }

    function test_Constructor_RevertsOnZeroThreshold() public {
        Tender.TenderConfig memory config = _configWithNK(3, 0);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidThreshold.selector, 0, 3));
        new Tender(config);
    }

    function test_Constructor_RevertsWhenThresholdNotMajority() public {
        Tender.TenderConfig memory config = _configWithNK(3, 1);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidThreshold.selector, 1, 3));
        new Tender(config);
    }

    function test_Constructor_RevertsOnExactHalfThreshold() public {
        Tender.TenderConfig memory config = _configWithNK(4, 2);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidThreshold.selector, 2, 4));
        new Tender(config);
    }

    function test_Constructor_RevertsWhenThresholdExceedsCount() public {
        Tender.TenderConfig memory config = _configWithNK(3, 4);
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidThreshold.selector, 4, 3));
        new Tender(config);
    }

    // ------------------------------------------------------------------ evaluator enc keys

    function test_Constructor_RevertsOnEncKeyCountMismatch() public {
        Tender.TenderConfig memory config = _defaultConfig();
        bytes[] memory keys = new bytes[](2);
        keys[0] = _encKey(1);
        keys[1] = _encKey(2);
        config.evaluatorEncKeys = keys;
        vm.expectRevert(abi.encodeWithSelector(Tender.EncKeyCountMismatch.selector, 2, 3));
        new Tender(config);
    }

    function test_Constructor_RevertsOnWrongSizedEncKey() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.evaluatorEncKeys[1] = hex"01"; // 1 byte, not 33
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidEncKey.selector, 1));
        new Tender(config);
    }

    // ------------------------------------------------------------------ evaluator validity

    function test_Constructor_RevertsOnZeroEvaluatorAddress() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.evaluators[1] = address(0);
        vm.expectRevert(Tender.ZeroAddress.selector);
        new Tender(config);
    }

    function test_Constructor_RevertsWhenEvaluatorIsPE() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.evaluators[0] = pe;
        vm.expectRevert(abi.encodeWithSelector(Tender.RoleConflict.selector, pe));
        new Tender(config);
    }

    function test_Constructor_RevertsWhenEvaluatorIsAppealsAuthority() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.evaluators[0] = appealsAuthority;
        vm.expectRevert(abi.encodeWithSelector(Tender.RoleConflict.selector, appealsAuthority));
        new Tender(config);
    }

    function test_Constructor_RevertsOnDuplicateEvaluator() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.evaluators[1] = eval1;
        vm.expectRevert(abi.encodeWithSelector(Tender.DuplicateEvaluator.selector, eval1));
        new Tender(config);
    }

    // ------------------------------------------------------------------ deposit / maxBidders / docs hash

    function test_Constructor_RevertsOnZeroDeposit() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.depositAmount = 0;
        vm.expectRevert(Tender.InvalidDeposit.selector);
        new Tender(config);
    }

    function test_Constructor_RevertsOnZeroMaxBidders() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.maxBidders = 0;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidMaxBidders.selector, 0));
        new Tender(config);
    }

    function test_Constructor_RevertsOnTooManyMaxBidders() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.maxBidders = 51;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidMaxBidders.selector, 51));
        new Tender(config);
    }

    function test_Constructor_AcceptsMaxBiddersCap() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.maxBidders = 50;
        new Tender(config);
    }

    function test_Constructor_RevertsOnZeroDocsHash() public {
        Tender.TenderConfig memory config = _defaultConfig();
        config.biddingDocsHash = bytes32(0);
        vm.expectRevert(Tender.ZeroHash.selector);
        new Tender(config);
    }

    // ------------------------------------------------------------------ schedule boundaries

    function test_Constructor_RevertsOnSchedule_SubmissionDeadlineTooSoon() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.submissionDeadline -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 1));
        new Tender(config);
    }

    function test_Constructor_RevertsOnSchedule_TechRevealEndTooSoon() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.techRevealEnd -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 2));
        new Tender(config);
    }

    function test_Constructor_RevertsOnSchedule_EvaluationEndTooSoon() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.evaluationEnd -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 3));
        new Tender(config);
    }

    function test_Constructor_RevertsOnSchedule_AppealFilingEndTooSoon() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.appealFilingEnd -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 4));
        new Tender(config);
    }

    function test_Constructor_RevertsOnSchedule_PriceRevealStartTooSoon() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.priceRevealStart -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 5));
        new Tender(config);
    }

    function test_Constructor_RevertsOnSchedule_PriceRevealEndTooSoon() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.priceRevealEnd -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 6));
        new Tender(config);
    }

    function test_Constructor_RevertsOnSchedule_AcceptanceWindowTooShort() public {
        Tender.TenderConfig memory config = _defaultConfig();
        Tender.Schedule memory s = _minSchedule();
        s.acceptanceWindow -= 1;
        config.schedule = s;
        vm.expectRevert(abi.encodeWithSelector(Tender.InvalidSchedule.selector, 7));
        new Tender(config);
    }
}
