// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

/// @notice Payload format shared by `CCIPGovernanceSender` (Ethereum) and `CCIPOwnerExecutor` (destinations).
/// @dev `keccak256(payload)` is the single identity of an operation on both sides: the sender's request id, the
///      executor's queue key and the argument of `CCIPOwnerExecutor.execute`.
library CCIPGovernancePayload {
    /// @dev Every call is made with zero value; there is deliberately no value field.
    struct Call {
        address target;
        bytes data;
    }

    uint8 internal constant VERSION = 1;
    uint8 internal constant PHASE_BOOTSTRAP = 1;
    uint8 internal constant PHASE_GOVERNOR = 2;
    uint256 internal constant MAX_CALLS = 8;

    function encode(uint256 chainId, address executor, uint64 opId, uint8 phase, uint64 deadline, Call[] memory calls)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VERSION, chainId, executor, opId, phase, deadline, calls);
    }

    function decode(bytes memory payload)
        internal
        pure
        returns (
            uint8 version,
            uint256 chainId,
            address executor,
            uint64 opId,
            uint8 phase,
            uint64 deadline,
            Call[] memory calls
        )
    {
        return abi.decode(payload, (uint8, uint256, address, uint64, uint8, uint64, Call[]));
    }
}
