// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Tender} from "../src/Tender.sol";
import {MockTLKR} from "../src/MockTLKR.sol";
import {DemoConstants} from "../script/DemoConstants.sol";
import {DeployLocal} from "../script/DeployLocal.s.sol";
import {CreateDemoTender} from "../script/CreateDemoTender.s.sol";
import {DemoCommit} from "../script/demo/01_Commit.s.sol";
import {DemoTechReveal} from "../script/demo/02_TechReveal.s.sol";
import {DemoVotes} from "../script/demo/03_Votes.s.sol";
import {DemoAppeal} from "../script/demo/04_Appeal.s.sol";
import {DemoPriceReveal} from "../script/demo/05_PriceReveal.s.sol";
import {DemoAccept} from "../script/demo/06_Accept.s.sol";
import {DemoSettle} from "../script/demo/07_Settle.s.sol";

/// @dev Runs every local-demo script exactly as `forge script` would (instantiate the
///      script contract, call `run()`), on the same in-process local EVM `forge test`
///      already provides -- Foundry's own recommended way to test a script -- so this
///      doubles as an end-to-end rehearsal of the demo video's exact sequence (Step 8,
///      item 4: "test that each script runs against a local fork/Anvil setup where
///      feasible"). `vm.warp` stands in for `demo.ps1`'s real `cast rpc evm_increaseTime`
///      between stages; it advances the same EVM clock the scripts themselves read via
///      `block.timestamp`; `DeploySepolia.s.sol` is excluded, since it requires a real
///      `--account` keystore and network and is checked by `forge build` only.
contract ScriptSmokeTest is Test, DemoConstants {
    function test_LocalDemo_FullLifecycle_EndToEnd() public {
        new DeployLocal().run();

        // Real Anvil time separates "register vendors" from "create tender" (see
        // CreateDemoTender.s.sol's doc comment); a plain `forge test` has no
        // simulate/broadcast split to lose, so `vm.warp` alone is sufficient here.
        vm.warp(block.timestamp + 1);
        new CreateDemoTender().run();

        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);
        MockTLKR token = MockTLKR(s.token);
        (, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);
        (, address treasuryAddr) = _key(IDX_TREASURY);

        new DemoCommit().run();
        assertEq(uint256(tender.getBid(bidderGood).state), 1); // Committed
        assertEq(uint256(tender.getBid(bidderWithholder).state), 1);

        vm.warp(tender.submissionDeadline());
        new DemoTechReveal().run(); // also exercises the late-commit revert
        assertEq(uint256(tender.getBid(bidderGood).state), 3); // Revealed
        assertEq(uint256(tender.getBid(bidderWithholder).state), 3);

        vm.warp(tender.techRevealEnd());
        new DemoVotes().run();
        assertEq(uint256(tender.getBid(bidderGood).state), 4); // Eligible
        assertEq(uint256(tender.getBid(bidderWithholder).state), 5); // Ineligible

        vm.warp(tender.evaluationEnd());
        new DemoAppeal().run();
        assertEq(uint256(tender.getBid(bidderWithholder).state), 4); // Eligible (appeal upheld)

        vm.warp(tender.priceRevealStart());
        new DemoPriceReveal().run();
        assertTrue(tender.getBid(bidderGood).opened);
        assertFalse(tender.getBid(bidderWithholder).opened); // deliberately withheld

        vm.warp(tender.priceRevealEnd());
        uint256 goodBalanceBeforeSettle = token.balanceOf(bidderGood);
        uint256 withholderBalanceBeforeSettle = token.balanceOf(bidderWithholder);
        uint256 treasuryBalanceBeforeSettle = token.balanceOf(treasuryAddr);
        new DemoAccept().run();
        assertEq(tender.winner(), bidderGood);

        new DemoSettle().run();
        assertEq(token.balanceOf(bidderGood), goodBalanceBeforeSettle + tender.depositAmount());
        assertEq(token.balanceOf(bidderWithholder), withholderBalanceBeforeSettle); // forfeited
        assertEq(
            token.balanceOf(treasuryAddr), treasuryBalanceBeforeSettle + tender.depositAmount()
        );
    }
}
