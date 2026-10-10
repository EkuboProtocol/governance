// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

/// @notice TESTNET-ONLY dummy target for the T2 CCIP owner-route rehearsal (EKU-1232). It stands in for the
///         production Positions/Orders contracts, which use the same solady `Ownable`, so `owner()`,
///         `transferOwnership` and the handover surface match. It holds nothing and controls nothing.
/// @dev Never deploy on Ethereum, BNB Chain or Monad mainnet (the T2 scripts refuse chains 1, 56 and 143).
contract T2DummyTarget is Ownable {
    uint256 public value;

    event ValueSet(uint256 value);
    event Noted(bytes32 indexed dataHash, uint256 length);

    constructor(address initialOwner) {
        _initializeOwner(initialOwner);
    }

    /// @notice The owner-gated call a delayed GOVERNOR operation makes in T2.
    function setValue(uint256 newValue) external onlyOwner {
        value = newValue;
        emit ValueSet(newValue);
    }

    /// @notice Owner-gated no-op that accepts arbitrary bytes; used to pad the forced-low-gas operation.
    function note(bytes calldata data) external onlyOwner {
        emit Noted(keccak256(data), data.length);
    }
}
