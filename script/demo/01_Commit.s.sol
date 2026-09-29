// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";
import {Tender} from "../../src/Tender.sol";
import {DemoConstants} from "../DemoConstants.sol";

/// @dev Demo stage 1/7 (Open): both demo bidders commit salted price commitments.
///      Run while `block.timestamp < submissionDeadline`.
contract DemoCommit is DemoConstants {
    function run() external {
        DemoState memory s = _readState();
        Tender tender = Tender(s.tender);

        (uint256 goodKey, address bidderGood) = _key(IDX_BIDDER_GOOD);
        (uint256 withholderKey, address bidderWithholder) = _key(IDX_BIDDER_WITHHOLDER);

        console.log("== Stage 1/7: Commit (Open) ==");
        console.log("Phase:", uint256(tender.currentPhase()));

        bytes32 commitmentGood = keccak256(
            abi.encode(block.chainid, address(tender), bidderGood, s.price, s.docHash, s.saltGood)
        );
        vm.startBroadcast(goodKey);
        tender.commit(commitmentGood, s.docHash, keccak256("demo-cipher-good"));
        vm.stopBroadcast();
        console.log("bidderGood committed:", bidderGood);

        bytes32 commitmentWithholder = keccak256(
            abi.encode(
                block.chainid,
                address(tender),
                bidderWithholder,
                s.price,
                s.docHash,
                s.saltWithholder
            )
        );
        vm.startBroadcast(withholderKey);
        tender.commit(commitmentWithholder, s.docHash, keccak256("demo-cipher-withholder"));
        vm.stopBroadcast();
        console.log("bidderWithholder committed:", bidderWithholder);
    }
}
