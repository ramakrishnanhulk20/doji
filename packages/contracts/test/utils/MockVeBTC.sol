// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {MockBTC} from "./MockBTC.sol";

/// @notice Stand-in for Mezo's veBTC. locked() returns 3 words (testnet shape) or 4 (mainnet shape), and
/// ownerOf returns the zero address for a missing id, as Mezo mainnet does. withdraw and unlockPermanent follow
/// the checks of the live Escrow library, and withdraw pays in a mock BTC ERC-20 as the live one pays through
/// the BTC ERC-20 view.
contract MockVeBTC is ERC721 {
    struct LockData {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    uint256 internal constant WEEK = 604_800;
    uint256 public constant MAX_LOCK_TIME = 28 days;

    uint256 public layoutWords;
    bool public transfersIgnored;
    MockBTC public immutable btc;

    mapping(uint256 tokenId => LockData) private _locks;
    mapping(uint256 tokenId => uint8) public escrowType;
    mapping(uint256 tokenId => address) public grantManager;
    mapping(uint256 tokenId => bool) public voted;
    mapping(uint256 tokenId => bool) public hasPayoutOverride;
    mapping(uint256 tokenId => uint256) public payoutOverride;

    error NotApprovedOrOwner();
    error AlreadyVoted();
    error NotNormalNFT();
    error PermanentLock();
    error NotPermanentLock();
    error LockNotExpired();

    constructor(uint256 layoutWords_, MockBTC btc_) ERC721("Mock veBTC", "veBTC") {
        layoutWords = layoutWords_;
        btc = btc_;
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

    /// @dev Open to anyone here; on Mezo only the voter flips this flag.
    function setVoted(uint256 tokenId, bool isVoted) external {
        voted[tokenId] = isVoted;
    }

    /// @dev Makes withdraw pay `amount` instead of the locked amount, to prove settle measures what arrives.
    function setWithdrawPayout(uint256 tokenId, uint256 amount) external {
        hasPayoutOverride[tokenId] = true;
        payoutOverride[tokenId] = amount;
    }

    /// @dev Makes transferFrom silently do nothing, to prove LoanManager checks custody after pulling.
    function setTransfersIgnored(bool ignored) external {
        transfersIgnored = ignored;
    }

    /// @dev Moves a token without approval, standing in for a veBTC flaw that takes custody away.
    function forceTransfer(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool) {
        return _isAuthorized(_ownerOf(tokenId), spender, tokenId);
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return _ownerOf(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (transfersIgnored) return;
        super.transferFrom(from, to, tokenId);
    }

    function withdraw(uint256 tokenId) external {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (voted[tokenId]) revert AlreadyVoted();
        if (escrowType[tokenId] != 0) revert NotNormalNFT();
        LockData memory lock = _locks[tokenId];
        if (lock.isPermanent) revert PermanentLock();
        if (block.timestamp < lock.end) revert LockNotExpired();
        uint256 value = hasPayoutOverride[tokenId] ? payoutOverride[tokenId] : uint256(int256(lock.amount));

        _burn(tokenId);
        delete _locks[tokenId];
        btc.mint(msg.sender, value);
    }

    function unlockPermanent(uint256 tokenId) external {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (escrowType[tokenId] != 0) revert NotNormalNFT();
        if (voted[tokenId]) revert AlreadyVoted();
        LockData storage lock = _locks[tokenId];
        if (!lock.isPermanent) revert NotPermanentLock();
        lock.isPermanent = false;
        lock.end = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;
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
