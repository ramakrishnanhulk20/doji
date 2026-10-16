// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Proves our fork tests can read one live veBTC position and the MUSD BTC price on
// Mezo mainnet and testnet. It does NOT cover: any write (no locks, transfers or
// approvals), borrowing or anything else in MUSD beyond fetchPrice, time travel
// (no warp or roll, so lock expiry and epochs are untested), token ids above 50, or
// running PriceFeed inside the local fork EVM. The price comes from the real node by
// eth_call at the fork block, because PriceFeed reads Mezo's Skip oracle precompile
// (0x7b7c...0015) and the bytecode stored there only forwards to itself, so the local
// EVM recurses until it reverts.

import {Test, console} from "forge-std/Test.sol";

interface IVeBTCRead {
    function ownerOf(uint256) external view returns (address);
    function escrowType(uint256) external view returns (uint8);
    function grantManager(uint256) external view returns (address);
}

interface IPriceFeed {
    function fetchPrice() external view returns (uint256);
}

contract ForkSmokeTest is Test {
    address internal constant MAINNET_VEBTC = 0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279;
    address internal constant MAINNET_PRICE_FEED = 0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88;
    address internal constant TESTNET_VEBTC = 0xB63fcCd03521Cf21907627bd7fA465C129479231;
    address internal constant TESTNET_PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;

    uint256 internal constant MAX_ID_TRIES = 50;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;

    // Mainnet locked() returns (amount, end, isPermanent, boost); the older testnet escrow has no boost word.
    uint256 internal constant MAINNET_LOCKED_BYTES = 128;
    uint256 internal constant TESTNET_LOCKED_BYTES = 96;

    error NoLiveToken(address ve, uint256 triedUpTo);
    error UnexpectedLockedLength(uint256 length);
    error UnexpectedPriceLength(uint256 length);

    function testMainnetVeBTCRead() public {
        vm.createSelectFork("mezo_mainnet");

        uint256 tokenId = _findLiveToken(MAINNET_VEBTC);
        bytes memory raw = _rawLocked(MAINNET_VEBTC, tokenId);
        assertEq(raw.length, MAINNET_LOCKED_BYTES, "mainnet locked() should return 4 words");
        (int128 amount, uint256 end, bool isPermanent) = _decodeLocked(raw);
        assertGt(int256(amount), 0, "mainnet locked amount should be positive");

        uint8 escrowType = IVeBTCRead(MAINNET_VEBTC).escrowType(tokenId);
        address grantManager = IVeBTCRead(MAINNET_VEBTC).grantManager(tokenId);

        uint256 price = _fetchPriceOnNode(MAINNET_PRICE_FEED);
        _assertPriceInRange(price);

        console.log("mainnet block", block.number);
        console.log("mainnet tokenId", tokenId);
        console.log("mainnet amount", int256(amount));
        console.log("mainnet end", end);
        console.log("mainnet isPermanent", isPermanent);
        console.log("mainnet escrowType", uint256(escrowType));
        console.log("mainnet grantManager", grantManager);
        console.log("mainnet price", price);
    }

    function testTestnetVeBTCRead() public {
        vm.createSelectFork("mezo_testnet");

        uint256 tokenId = _findLiveToken(TESTNET_VEBTC);
        bytes memory raw = _rawLocked(TESTNET_VEBTC, tokenId);
        assertEq(raw.length, TESTNET_LOCKED_BYTES, "testnet locked() should return 3 words");
        (int128 amount, uint256 end, bool isPermanent) = _decodeLocked(raw);
        assertGt(int256(amount), 0, "testnet locked amount should be positive");

        uint256 price = _fetchPriceOnNode(TESTNET_PRICE_FEED);
        _assertPriceInRange(price);

        console.log("testnet block", block.number);
        console.log("testnet tokenId", tokenId);
        console.log("testnet amount", int256(amount));
        console.log("testnet end", end);
        console.log("testnet isPermanent", isPermanent);
        console.log("testnet price", price);
    }

    /// @dev A zero owner is treated as not live too, because some vote-escrow forks
    /// return address(0) for a burned id instead of reverting.
    function _findLiveToken(address ve) internal view returns (uint256) {
        for (uint256 id = 1; id <= MAX_ID_TRIES; ++id) {
            try IVeBTCRead(ve).ownerOf(id) returns (address owner) {
                if (owner != address(0)) return id;
            } catch {}
        }
        revert NoLiveToken(ve, MAX_ID_TRIES);
    }

    /// @dev Low-level call because the return shape differs between the two networks.
    function _rawLocked(address ve, uint256 tokenId) internal view returns (bytes memory raw) {
        bool ok;
        (ok, raw) = ve.staticcall(abi.encodeWithSignature("locked(uint256)", tokenId));
        assertTrue(ok, "locked() reverted");
    }

    /// @dev abi.decode rejects a dirty int128 or bool word, so a layout we did not
    /// expect fails here instead of producing a wrong number.
    function _decodeLocked(bytes memory raw)
        internal
        pure
        returns (int128 amount, uint256 end, bool isPermanent)
    {
        if (raw.length == MAINNET_LOCKED_BYTES) {
            (amount, end, isPermanent,) = abi.decode(raw, (int128, uint256, bool, uint256));
        } else if (raw.length == TESTNET_LOCKED_BYTES) {
            (amount, end, isPermanent) = abi.decode(raw, (int128, uint256, bool));
        } else {
            revert UnexpectedLockedLength(raw.length);
        }
    }

    /// @dev Pinned to the fork block so the price and the veBTC read come from the same state.
    function _fetchPriceOnNode(address feed) internal returns (uint256) {
        string memory params = string.concat(
            '[{"to":"',
            vm.toString(feed),
            '","data":"',
            vm.toString(abi.encodeWithSelector(IPriceFeed.fetchPrice.selector)),
            '"},"',
            _hexQuantity(block.number),
            '"]'
        );
        bytes memory raw = vm.rpc("eth_call", params);
        if (raw.length != 32) revert UnexpectedPriceLength(raw.length);
        return abi.decode(raw, (uint256));
    }

    /// @dev JSON-RPC block numbers must be hex with no leading zeros, which vm.toString does not produce.
    function _hexQuantity(uint256 value) internal pure returns (string memory) {
        bytes memory padded = bytes(vm.toString(bytes32(value)));
        uint256 start = 2;
        while (start < padded.length - 1 && padded[start] == "0") ++start;
        bytes memory out = new bytes(padded.length - start + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = start; i < padded.length; ++i) {
            out[i - start + 2] = padded[i];
        }
        return string(out);
    }

    function _assertPriceInRange(uint256 price) internal pure {
        assertGe(price, MIN_BTC_PRICE, "BTC price below sanity floor");
        assertLe(price, MAX_BTC_PRICE, "BTC price above sanity ceiling");
    }
}
