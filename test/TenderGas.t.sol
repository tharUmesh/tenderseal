// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../src/Tender.sol";
import {TenderFactory} from "../src/TenderFactory.sol";
import {TenderTestBase} from "./utils/TenderTestBase.sol";

/// @dev Gas benchmarks (SPEC §10 Step 7): tender creation, and a full 20-bidder flow
///      (commit, castVote, revealPrice, acceptAward, settle, ranking) for n=3 and n=5
///      evaluators. Read via `forge test --match-contract TenderGasTest --gas-report`.
///
///      Deployment/creation costs are read from `vm.lastFrameGas()` rather than the
///      `[PASS] ... (gas: N)` summary number, a manual `gasleft()` delta, or the
///      gas-report's "Deployment Cost" column: the summary number and a `gasleft()` delta
///      both under-report by ~1000x for a bare top-level `new` statement in a test, and
///      "Deployment Cost" reads 0 for a contract not deployed as the test's own top-level
///      call. `lastFrameGas().gasTotalUsed` matches the `-vvvv` call trace's own per-call
///      CREATE gas figure.
contract TenderGasTest is TenderTestBase {
    uint256 internal constant NUM_BIDDERS = 20;

    function test_Gas_TenderCreation_N3Evaluators() public {
        vm.warp(T0 + 1 hours);
        Tender.TenderConfig memory config = _defaultConfig(); // n=3, k=2
        new Tender(config);
        console.log("Tender creation gas (n=3):", vm.lastFrameGas().gasTotalUsed);
    }

    function test_Gas_TenderCreation_N5Evaluators() public {
        vm.warp(T0 + 1 hours);
        Tender.TenderConfig memory config = _configWithEvaluators(5, 3);
        new Tender(config);
        console.log("Tender creation gas (n=5):", vm.lastFrameGas().gasTotalUsed);
    }

    function test_Gas_FactoryDeployment() public {
        new TenderFactory(address(registry), address(token));
        console.log("TenderFactory deployment gas:", vm.lastFrameGas().gasTotalUsed);
    }

    function test_Gas_Factory_CreateTender() public {
        TenderFactory factory = new TenderFactory(address(registry), address(token));
        Tender.TenderConfig memory config = _defaultConfig(); // n=3, k=2

        vm.prank(pe);
        factory.createTender(config);
        console.log("TenderFactory.createTender gas (n=3):", vm.lastFrameGas().gasTotalUsed);
    }

    function test_Gas_FullFlow_20Bidders_N3Evaluators() public {
        _runFullFlowGasBenchmark(3, 2);
    }

    function test_Gas_FullFlow_20Bidders_N5Evaluators() public {
        _runFullFlowGasBenchmark(5, 3);
    }

    function _configWithEvaluators(uint256 n, uint8 k)
        internal
        view
        returns (Tender.TenderConfig memory config)
    {
        config = _defaultConfig();
        address[] memory evals = new address[](n);
        bytes[] memory keys = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            evals[i] = vm.addr(9000 + i);
            keys[i] = _encKey(9000 + i);
        }
        config.evaluators = evals;
        config.evaluatorEncKeys = keys;
        config.threshold = k;
        config.maxBidders = NUM_BIDDERS;
    }

    function _runFullFlowGasBenchmark(uint256 n, uint8 k) internal {
        address[] memory evaluators = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            evaluators[i] = vm.addr(9000 + i);
        }

        address[] memory bidders = new address[](NUM_BIDDERS);
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            bidders[i] = makeAddr(string.concat("gasBidder", vm.toString(n), vm.toString(i)));
            _registerVendor(bidders[i], keccak256(abi.encode("gasBidder", n, i)));
        }

        vm.warp(T0 + 1 hours);
        Tender tender = new Tender(_configWithEvaluators(n, k));

        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            vm.prank(admin);
            token.mint(bidders[i], DEPOSIT * 10);
            vm.prank(bidders[i]);
            token.approve(address(tender), type(uint256).max);
        }

        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            bytes32 commitment = keccak256(
                abi.encode(
                    block.chainid,
                    address(tender),
                    bidders[i],
                    i + 1,
                    keccak256("doc"),
                    keccak256(abi.encode("salt", i))
                )
            );
            vm.prank(bidders[i]);
            tender.commit(commitment, keccak256("doc"), keccak256("cipher"));
        }

        vm.warp(tender.submissionDeadline());
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            vm.prank(bidders[i]);
            tender.postKeyEnvelope(keccak256("key"));
        }

        vm.warp(tender.techRevealEnd());
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            for (uint256 e = 0; e < k; e++) {
                vm.prank(evaluators[e]);
                tender.castVote(bidders[i], true, 1, keccak256("report"));
            }
        }

        vm.warp(tender.priceRevealStart());
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            tender.revealPrice(bidders[i], i + 1, keccak256(abi.encode("salt", i)));
        }

        tender.ranking(); // ranking cost with all 20 bidders ranked

        vm.warp(tender.priceRevealEnd());
        vm.prank(bidders[0]); // cheapest (price = 1)
        tender.acceptAward();

        vm.prank(pe);
        tender.acknowledgeAward();

        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            tender.settle(bidders[i]);
        }
    }
}
