// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LockReader
/// @notice The single decoder for veBTC's locked(). Mezo testnet returns (amount, end, isPermanent) and
///         mainnet appends a boost word, so the caller states the layout it expects and anything else fails.
library LockReader {
    error LockReadFailed();
    error BadLockAmount();

    /// @notice Reads and validates a position's lock.
    /// @dev Reverts LockReadFailed if the call fails or returns any size other than `layoutWords` words, and
    ///      BadLockAmount if the amount is zero or negative. abi.decode also reverts on a dirty int128 or bool
    ///      word. A permanent lock reports end = 0; callers must treat it as never expiring.
    /// @param veBTC veBTC contract.
    /// @param tokenId Position id.
    /// @param layoutWords 3 on testnet, 4 on mainnet.
    /// @return amount Locked BTC in wei, always above zero.
    /// @return end Unlock time, a Thursday 00:00 UTC, or 0 for a permanent lock.
    /// @return isPermanent True for a permanent lock.
    function read(address veBTC, uint256 tokenId, uint256 layoutWords)
        internal
        view
        returns (uint256 amount, uint256 end, bool isPermanent)
    {
        (bool ok, bytes memory data) = veBTC.staticcall(abi.encodeWithSignature("locked(uint256)", tokenId));
        if (!ok || data.length != layoutWords * 32) revert LockReadFailed();
        int128 signedAmount;
        (signedAmount, end, isPermanent) = abi.decode(data, (int128, uint256, bool));
        if (signedAmount <= 0) revert BadLockAmount();
        amount = SafeCast.toUint256(int256(signedAmount));
    }
}
