// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Stand-in for Mezo's veBTC. locked() returns 3 words (testnet shape) or 4 (mainnet shape), and
/// ownerOf returns the zero address for a missing id, as Mezo mainnet does.
contract MockVeBTC is ERC721 {
    struct LockData {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    uint256 public layoutWords;
    bool public transfersIgnored;

    mapping(uint256 tokenId => LockData) private _locks;
    mapping(uint256 tokenId => uint8) public escrowType;
    mapping(uint256 tokenId => address) public grantManager;
    mapping(uint256 tokenId => bool) public voted;

    constructor(uint256 layoutWords_) ERC721("Mock veBTC", "veBTC") {
        layoutWords = layoutWords_;
    }

    function mint(address to, uint256 tokenId, int128 amount, uint256 end, bool isPermanent) external {
        _mint(to, tokenId);
        _locks[tokenId] = LockData(amount, end, isPermanent);
    }

    function setLock(uint256 tokenId, int128 amount, uint256 end, bool isPermanent) external {
        _locks[tokenId] = LockData(amount, end, isPermanent);
    }

    function setLayoutWords(uint256 words) external {
        layoutWords = words;
    }

    function setEscrowType(uint256 tokenId, uint8 kind) external {
        escrowType[tokenId] = kind;
    }

    function setGrantManager(uint256 tokenId, address manager) external {
        grantManager[tokenId] = manager;
    }

    function setVoted(uint256 tokenId, bool isVoted) external {
        voted[tokenId] = isVoted;
    }

    /// @dev Makes transferFrom silently do nothing, to prove LoanManager checks custody after pulling.
    function setTransfersIgnored(bool ignored) external {
        transfersIgnored = ignored;
    }

    /// @dev Moves a token without approval, standing in for a veBTC flaw that takes custody away.
    function forceTransfer(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return _ownerOf(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (transfersIgnored) return;
        super.transferFrom(from, to, tokenId);
    }

    function locked(uint256 tokenId) external view {
        LockData memory lock = _locks[tokenId];
        bytes memory out = layoutWords == 4
            ? abi.encode(lock.amount, lock.end, lock.isPermanent, uint256(1e18))
            : abi.encode(lock.amount, lock.end, lock.isPermanent);
        assembly {
            return(add(out, 32), mload(out))
        }
    }
}
