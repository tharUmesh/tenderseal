// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {TenderFactory} from "../src/TenderFactory.sol";
import {MockTLKR} from "../src/MockTLKR.sol";
import {Tender} from "../src/Tender.sol";
import {DemoConstants} from "./DemoConstants.sol";

/// @dev Local Anvil demo deploy, part 2/2 (SPEC §10 Step 8): creates the demo tender and
///      funds/approves both demo bidders.
///
///      Deliberately a SEPARATE script/broadcast from `DeployLocal.s.sol`, not one more
///      step in it: `Tender.createdAt` and `VendorRegistry.registeredAt` are both captured
///      from `block.timestamp` at the moment each transaction actually executes ON CHAIN
///      -- and `vm.warp` inside a script only affects that script's own local
///      simulation, never the real broadcast. Two transactions broadcast back-to-back by
///      ONE script can land in the same Anvil block with the SAME real timestamp, so
///      `registeredAt < createdAt` (I8, strict) is not guaranteed unless real chain time
///      actually passes between "register vendors" and "create tender" -- which
///      `demo.ps1` provides with an explicit `cast rpc evm_increaseTime` between the two
///      script calls. (`test/ScriptSmoke.t.sol` instead uses `vm.warp` directly, since a
///      plain `forge test` has no separate simulate/broadcast split for it to lose.)
///
///      Run against a local Anvil node, after DeployLocal.s.sol and some real elapsed time:
///        forge script script/CreateDemoTender.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract CreateDemoTender is DemoConstants {
    function run() external {
        console.log("== TenderSeal local demo deploy (2/2): tender + funding ==");

        DemoState memory s = _readState();
        TenderFactory factory = TenderFactory(s.factory);

        Tender tender = _createTender(factory);
        _fundBidders(MockTLKR(s.token), tender);

        s.tender = address(tender);
        s.price = 250_000_00;
        s.docHash = keccak256("demo-doc-v1");
        s.saltGood = keccak256("demo-salt-good");
        s.saltWithholder = keccak256("demo-salt-withholder");
        _writeState(s);

        console.log("== Deploy complete ==");
        console.log("Tender:", address(tender));
    }

    /// @dev A few-minutes schedule so the whole lifecycle fits in one short recording,
    ///      while every gap still satisfies MIN_WINDOW = 60s.
    function _buildSchedule() internal view returns (Tender.Schedule memory schedule) {
        uint64 nowTs = uint64(block.timestamp);
        schedule = Tender.Schedule({
            submissionDeadline: nowTs + 3 minutes,
            techRevealEnd: nowTs + 6 minutes,
            evaluationEnd: nowTs + 9 minutes,
            appealFilingEnd: nowTs + 12 minutes,
            priceRevealStart: nowTs + 15 minutes,
            priceRevealEnd: nowTs + 18 minutes,
            acceptanceWindow: 3 minutes
        });
        console.log("  submissionDeadline:", schedule.submissionDeadline);
        console.log("  techRevealEnd:     ", schedule.techRevealEnd);
        console.log("  evaluationEnd:     ", schedule.evaluationEnd);
        console.log("  appealFilingEnd:   ", schedule.appealFilingEnd);
        console.log("  priceRevealStart:  ", schedule.priceRevealStart);
        console.log("  priceRevealEnd:    ", schedule.priceRevealEnd);
    }

    function _buildConfig(TenderFactory factory)
        internal
        view
        returns (Tender.TenderConfig memory config)
    {
        (, address eval1) = _key(IDX_EVAL1);
        (, address eval2) = _key(IDX_EVAL2);
        (, address eval3) = _key(IDX_EVAL3);
        address[] memory evaluators = new address[](3);
        evaluators[0] = eval1;
        evaluators[1] = eval2;
        evaluators[2] = eval3;
        bytes[] memory encKeys = new bytes[](3);
        encKeys[0] = abi.encodePacked(uint8(0x02), keccak256("demo-enc-key-1"));
        encKeys[1] = abi.encodePacked(uint8(0x02), keccak256("demo-enc-key-2"));
        encKeys[2] = abi.encodePacked(uint8(0x02), keccak256("demo-enc-key-3"));

        (, address peAddr) = _key(IDX_PE);
        (, address authorityAddr) = _key(IDX_AUTHORITY);
        (, address treasuryAddr) = _key(IDX_TREASURY);

        config = Tender.TenderConfig({
            registry: factory.registry(),
            token: factory.token(),
            pe: peAddr,
            appealsAuthority: authorityAddr,
            treasury: treasuryAddr,
            evaluators: evaluators,
            evaluatorEncKeys: encKeys,
            threshold: 2,
            depositAmount: 100_000_00, // 100,000.00 tLKR
            maxBidders: 20,
            biddingDocsHash: keccak256("demo-bidding-docs-v1"),
            schedule: _buildSchedule()
        });
    }

    function _createTender(TenderFactory factory) internal returns (Tender tender) {
        Tender.TenderConfig memory config = _buildConfig(factory);
        (uint256 peKey,) = _key(IDX_PE);

        vm.startBroadcast(peKey);
        tender = factory.createTender(config);
        vm.stopBroadcast();

        console.log("Tender created:", address(tender));
    }

    function _fundBidders(MockTLKR token, Tender tender) internal {
        (uint256 deployerKey,) = _key(IDX_DEPLOYER);
        (, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);

        vm.startBroadcast(deployerKey);
        token.mint(bidderGood, 1_000_000_00);
        token.mint(bidderWithholder, 1_000_000_00);
        vm.stopBroadcast();

        (uint256 bidderGoodKey,) = _key(IDX_BIDDER_GOOD);
        vm.startBroadcast(bidderGoodKey);
        token.approve(address(tender), type(uint256).max);
        vm.stopBroadcast();

        (uint256 bidderWithholderKey,) = _key(IDX_BIDDER_WITHHOLDER);
        vm.startBroadcast(bidderWithholderKey);
        token.approve(address(tender), type(uint256).max);
        vm.stopBroadcast();

        console.log("Funded and approved both demo bidders");
    }
}
