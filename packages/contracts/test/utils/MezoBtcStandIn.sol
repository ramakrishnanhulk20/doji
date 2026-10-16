// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Local stand-in for Mezo's BTC ERC-20 precompile at 0x7b7C...0000, for scripts and fork tests only.
/// @dev On Mezo the ERC-20 view and native BTC are one balance, but the precompile's stored bytecode only
///      calls itself, so a local EVM recurses until it reverts. Etched over that address, this contract
///      reads each account's native balance and records ERC-20 movements as a signed adjustment on top.
///      Native BTC never moves through it, so it must never be deployed to a real chain.
contract MezoBtcStandIn {
    mapping(address account => int256) public adjustment;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address owner, address spender, uint256 allowed, uint256 needed);

    function name() external pure returns (string memory) {
        return "BTC";
    }

    function symbol() external pure returns (string memory) {
        return "BTC";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address account) public view returns (uint256) {
        return uint256(int256(account.balance) + adjustment[account]);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert InsufficientAllowance(from, msg.sender, allowed, value);
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        uint256 balance = balanceOf(from);
        if (balance < value) revert InsufficientBalance(from, balance, value);
        adjustment[from] -= int256(value);
        adjustment[to] += int256(value);
        emit Transfer(from, to, value);
    }
}
