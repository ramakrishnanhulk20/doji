// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Stand-in for MUSD's PriceFeed: a settable 18-decimal BTC price that can be made to revert.
contract MockPriceFeed {
    uint256 public price;
    bool public stale;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function setStale(bool isStale) external {
        stale = isStale;
    }

    function fetchPrice() external view returns (uint256) {
        require(!stale, "PriceFeed: Oracle is stale.");
        return price;
    }
}
