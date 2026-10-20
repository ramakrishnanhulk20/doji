// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain 18-decimal ERC-20 standing in for MUSD, with open minting for tests. It can be told to refuse
///         chosen recipients, the way Liquity-style MUSD refuses some system addresses.
contract MockMUSD is ERC20 {
    error RecipientRefused(address to);

    mapping(address account => bool) public refused;

    constructor() ERC20("Mezo USD", "MUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRefused(address account, bool isRefused) external {
        refused[account] = isRefused;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (refused[to]) revert RecipientRefused(to);
        super._update(from, to, value);
    }
}
