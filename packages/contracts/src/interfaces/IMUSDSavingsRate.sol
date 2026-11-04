// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Mezo's sMUSD vault: testnet 0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16, mainnet 0xb4D498029af77680cD1eF828b967f010d06C51CC.
interface IMUSDSavingsRate {
    /// @notice Pulls `amount` MUSD from the caller with transferFrom and mints the caller exactly `amount` sMUSD,
    ///         a 1:1 receipt rather than an ERC-4626 share.
    function deposit(uint256 amount) external;

    /// @notice Burns `amount` of the caller's sMUSD and pays it `amount` MUSD plus its accrued yield.
    function withdraw(uint256 amount) external;

    /// @notice Pays the caller its accrued yield in MUSD and returns the amount paid.
    function claimYield() external returns (uint256);

    /// @notice Cumulative MUSD yield per sMUSD, scaled by 1e18. Only ever rises in the verified code.
    function yieldIndex() external view returns (uint256);

    /// @notice sMUSD held by `account`, equal to its MUSD principal in the vault.
    function balanceOf(address account) external view returns (uint256);

    /// @notice The MUSD token the vault takes and pays.
    function musdToken() external view returns (address);
}
