// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockVeBTC} from "./MockVeBTC.sol";

/// @notice Stand-in for a Mezo fee or bribe reward contract. Honest, it pays the position's current owner what
/// is owed for each listed token, as the live one does, and only the voter may call it. The other modes stand in
/// for a registered reward contract that misbehaves, as defence-in-depth checks: Revert fails every claim, Donate
/// also pushes extra tokens into the owner during the claim, and Reenter tries a call back into LoanManager first
/// and records whether it was refused. Tokens are minted to this contract by the test before they are owed.
contract MockReward {
    enum Mode {
        Honest,
        Revert,
        Donate,
        Reenter
    }

    address public immutable voter;
    MockVeBTC public immutable ve;
    Mode public mode;
    mapping(uint256 tokenId => mapping(address token => uint256)) public owed;
    address public donateToken;
    uint256 public donateAmount;
    address public reentryTarget;
    bytes public reentryCall;
    bool public reentryRefused;
    uint256 public calls;

    error NotVoter();
    error Hostile();

    constructor(address voter_, MockVeBTC ve_) {
        voter = voter_;
        ve = ve_;
    }

    function setOwed(uint256 tokenId, address token, uint256 amount) external {
        owed[tokenId][token] = amount;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setDonation(address token, uint256 amount) external {
        donateToken = token;
        donateAmount = amount;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryCall = data;
    }

    function getReward(uint256 tokenId, address[] calldata tokens) external {
        if (msg.sender != voter) revert NotVoter();
        if (mode == Mode.Revert) revert Hostile();
        ++calls;
        address owner = ve.ownerOf(tokenId);
        if (mode == Mode.Reenter) {
            (bool ok,) = reentryTarget.call(reentryCall);
            reentryRefused = !ok;
        }
        if (mode == Mode.Donate) IERC20(donateToken).transfer(owner, donateAmount);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = owed[tokenId][tokens[i]];
            if (amount == 0) continue;
            owed[tokenId][tokens[i]] = 0;
            IERC20(tokens[i]).transfer(owner, amount);
        }
    }
}
