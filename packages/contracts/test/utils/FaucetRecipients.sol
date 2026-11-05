// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFaucet} from "../../src/interfaces/IFaucet.sol";

/// @notice Refuses every BTC payment, so a claim for it must revert whole.
contract RefusingRecipient {
    error Refused();

    receive() external payable {
        revert Refused();
    }
}

/// @notice Spins until its gas runs out: the most a recipient can cost the relayer.
contract LoopingRecipient {
    uint256 public spins;

    receive() external payable {
        while (true) {
            ++spins;
        }
    }
}

/// @notice Answers a BTC payment with `size` bytes, which a caller that copied return data would pay to hold.
contract ReturnBombRecipient {
    uint256 public immutable size;

    constructor(uint256 size_) {
        size = size_;
    }

    receive() external payable {
        uint256 length = size;
        assembly {
            return(0, length)
        }
    }
}

/// @notice Calls back into the faucet from its receive, asking for a kit for `victim`. With `bubble` it fails the
///         payment when refused, otherwise it swallows the refusal and keeps the coins.
contract ReenteringRecipient {
    IFaucet internal immutable faucet;
    address internal immutable victim;
    bool internal immutable bubble;

    bool public secondClaimLanded;
    bytes4 public refusal;

    constructor(IFaucet faucet_, address victim_, bool bubble_) {
        faucet = faucet_;
        victim = victim_;
        bubble = bubble_;
    }

    receive() external payable {
        (bool ok, bytes memory raw) = address(faucet).call(abi.encodeCall(IFaucet.claim, (victim)));
        if (ok) {
            secondClaimLanded = true;
            return;
        }
        if (bubble) {
            assembly {
                revert(add(raw, 32), mload(raw))
            }
        }
        refusal = bytes4(raw);
    }
}

/// @notice A contract that is itself the relayer and claims for itself, so its callback passes the relayer check
///         and only the reentrancy lock can stop it.
contract ReenteringRelayer {
    IFaucet internal immutable faucet;
    address internal immutable victim;

    bytes4 public refusal;

    constructor(IFaucet faucet_, address victim_) {
        faucet = faucet_;
        victim = victim_;
    }

    function claimForSelf() external {
        faucet.claim(address(this));
    }

    receive() external payable {
        (, bytes memory raw) = address(faucet).call(abi.encodeCall(IFaucet.claim, (victim)));
        refusal = bytes4(raw);
    }
}

/// @notice Records the gas it was handed, to pin down what the faucet forwards.
contract GasProbeRecipient {
    uint256 public gasAtEntry;

    receive() external payable {
        gasAtEntry = gasleft();
    }
}

/// @notice The part of a Safe wallet a plain payment reaches: an event from the shared code.
contract SafeStyleSingleton {
    event SafeReceived(address indexed sender, uint256 value);

    receive() external payable {
        emit SafeReceived(msg.sender, msg.value);
    }
}

/// @notice A Safe-style proxy: the shared code's address in slot 0, and every call forwarded to it by delegatecall.
contract SafeStyleProxy {
    address internal singleton;

    constructor(address singleton_) {
        singleton = singleton_;
    }

    receive() external payable {
        _forward();
    }

    fallback() external payable {
        _forward();
    }

    function _forward() private {
        assembly {
            let target := and(sload(0), 0xffffffffffffffffffffffffffffffffffffffff)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
