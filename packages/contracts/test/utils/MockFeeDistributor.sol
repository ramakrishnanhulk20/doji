// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockBTC} from "./MockBTC.sol";
import {MockVeBTC} from "./MockVeBTC.sol";

/// @notice Stand-in for Mezo's veBTC fee distributor with the live claim rule from the verified source: anyone
/// may claim for any position; on an unexpired or permanent lock the BTC is added to the lock with depositFor,
/// and on an expired normal lock it is paid to the position's owner.
contract MockFeeDistributor {
    MockVeBTC public immutable ve;
    MockBTC public immutable btc;
    mapping(uint256 tokenId => uint256) public claimable;

    constructor(MockVeBTC ve_, MockBTC btc_) {
        ve = ve_;
        btc = btc_;
        btc_.approve(address(ve_), type(uint256).max);
    }

    /// @dev Mints the BTC the claim will pay, as the live distributor holds it before a checkpoint.
    function setClaimable(uint256 tokenId, uint256 amount) external {
        claimable[tokenId] = amount;
        btc.mint(address(this), amount);
    }

    function claim(uint256 tokenId) external returns (uint256 amount) {
        amount = claimable[tokenId];
        if (amount == 0) return 0;
        claimable[tokenId] = 0;
        (, uint256 end, bool isPermanent) = ve.lockData(tokenId);
        if (block.timestamp >= end && !isPermanent) {
            btc.transfer(ve.ownerOf(tokenId), amount);
        } else {
            ve.depositFor(tokenId, amount);
        }
    }
}
