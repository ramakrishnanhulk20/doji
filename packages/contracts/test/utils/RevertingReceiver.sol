// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";

/// @notice A lender contract that refuses every token hook. If any Dojima flow ran its code, that flow
/// would revert, so a borrow that succeeds against its offer proves no maker code ran.
contract RevertingReceiver {
    error Refused();

    function postOffer(ICreditMarkets markets, IERC20 musd, uint64 maturity, uint16 aprBps, uint128 amount)
        external
        returns (uint256)
    {
        musd.approve(address(markets), amount);
        return markets.postOffer(maturity, aprBps, amount);
    }

    function claimUnits(ICreditMarkets markets, uint64 maturity) external returns (uint256) {
        return markets.claimUnits(maturity);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Refused();
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert Refused();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert Refused();
    }
}
