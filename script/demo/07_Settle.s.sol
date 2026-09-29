// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {MockTLKR} from "../../src/MockTLKR.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 7/7 (Final): settle both deposits. bidderGood (the winner) is
///      refunded; bidderWithholder (Eligible but never opened, terminal cause
///      AwardAccepted) is forfeited under F2 -- its deposit lands in `treasury`. Anyone
///      may call `settle`; this uses the deployer for both calls.
contract DemoSettle is DemoConstants {
    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);
        MockTLKR token = MockTLKR(s.token);
        (uint256 deployerKey,) = _key(IDX_DEPLOYER);
        (, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);
        (, address treasuryAddr) = _key(IDX_TREASURY);

        console.log("== Stage 7/7: Settle (Final) ==");
        console.log("Phase:", uint256(tender.currentPhase()));
        console.log("Treasury balance before:", token.balanceOf(treasuryAddr));
        console.log("bidderGood balance before:", token.balanceOf(bidderGood));
        console.log("bidderWithholder balance before:", token.balanceOf(bidderWithholder));

        vm.startBroadcast(deployerKey);
        tender.settle(bidderGood);
        tender.settle(bidderWithholder);
        vm.stopBroadcast();

        console.log("-- after settle --");
        console.log("Treasury balance after:", token.balanceOf(treasuryAddr));
        console.log("bidderGood balance after (Refund, winner):", token.balanceOf(bidderGood));
        console.log(
            "bidderWithholder balance after (Forfeit F2, withheld price):",
            token.balanceOf(bidderWithholder)
        );
    }
}
