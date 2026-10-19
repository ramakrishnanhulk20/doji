// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain 18-decimal ERC-20 standing in for Mezo's BTC ERC-20 view, with open minting for tests.
contract MockBTC is ERC20 {
    constructor() ERC20("Bitcoin", "BTC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
