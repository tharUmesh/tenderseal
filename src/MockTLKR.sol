// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockTLKR
/// @notice Test token representing an LKR-denominated bid security (prototype only).
/// @dev In a real deployment the bid security would be a bank guarantee or a regulated
///      stable-value instrument; this token only models the accounting. 2 decimals (cents).
contract MockTLKR is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("Test Sri Lankan Rupee", "tLKR")
        Ownable(initialOwner)
    {}

    function decimals() public pure override returns (uint8) {
        return 2;
    }

    /// @notice Mint test tokens (owner only).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
