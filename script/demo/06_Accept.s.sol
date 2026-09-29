// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 6/7 (Acceptance -> Final): bidderGood is the only ranked bid (the only
///      one that opened), so it is round 1's offeree; it accepts, then the PE
///      acknowledges the award (event only). Run at/after `priceRevealEnd`.
contract DemoAccept is DemoConstants {
    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);
        (uint256 goodKey, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (uint256 peKey,) = _key(IDX_PE);

        console.log("== Stage 6/7: Accept (Acceptance) ==");
        console.log("Phase:", uint256(tender.currentPhase()));
        (uint256 round, address offeree,) = tender.currentOffer();
        console.log("Round:", round);
        console.log("Offeree:", offeree);

        vm.startBroadcast(goodKey);
        tender.acceptAward();
        vm.stopBroadcast();
        console.log("bidderGood accepted the award:", bidderGood);

        vm.startBroadcast(peKey);
        tender.acknowledgeAward();
        vm.stopBroadcast();
        console.log("PE acknowledged the award (event only)");
        console.log("Phase now:", uint256(tender.currentPhase()));
    }
}
