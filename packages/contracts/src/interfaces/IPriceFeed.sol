// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPriceFeed
/// @notice MUSD's BTC price feed on Mezo, backed by the Skip oracle.
interface IPriceFeed {
    /// @notice USD per BTC with 18 decimals. Reverts when the oracle is more than 60 seconds old.
    function fetchPrice() external view returns (uint256);
}
