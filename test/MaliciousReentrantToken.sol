// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev TEST-ONLY minimal ERC20 whose `transfer`/`transferFrom` can be "armed" to attempt
///      one reentrant call into an arbitrary target before completing the transfer. The
///      reentrant attempt's outcome is captured (not reverted through), so the outer
///      transfer itself always completes normally -- exactly what's needed to prove a
///      `nonReentrant` guard blocks the *inner* call without conflating that with an
///      unrelated failure of the outer one.
contract MaliciousReentrantToken is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    address public target;
    bytes public reentrantCalldata;
    bool public armed;

    bool public lastReentryAttempted;
    bool public lastReentryOk;
    bytes public lastReentryReturnData;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Arms a one-shot reentrant call against `target_` for the next transfer.
    function arm(address target_, bytes calldata data) external {
        target = target_;
        reentrantCalldata = data;
        armed = true;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _reenterIfArmed();
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _reenterIfArmed();
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            _allowances[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _reenterIfArmed() internal {
        if (!armed) return;
        armed = false; // one-shot: avoid infinite recursion
        lastReentryAttempted = true;
        (bool ok, bytes memory ret) = target.call(reentrantCalldata);
        lastReentryOk = ok;
        lastReentryReturnData = ret;
    }
}
