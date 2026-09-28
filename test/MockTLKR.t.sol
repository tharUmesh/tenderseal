// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockTLKR} from "../src/MockTLKR.sol";

contract MockTLKRTest is Test {
    MockTLKR internal token;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new MockTLKR(owner);
    }

    function test_Metadata() public view {
        assertEq(token.name(), "Test Sri Lankan Rupee");
        assertEq(token.symbol(), "tLKR");
        assertEq(token.decimals(), 2); // amounts are in cents
    }

    function test_OwnerCanMint() public {
        vm.prank(owner);
        token.mint(alice, 250_000_00); // LKR 250,000.00
        assertEq(token.balanceOf(alice), 250_000_00);
    }

    function test_NonOwnerCannotMint() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.mint(alice, 1);
    }
}
