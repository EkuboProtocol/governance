// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

/// @notice Base for owner proxies on chains without an L1-aliased messenger, controlled from Ethereum through a
///         bridge that reports the Ethereum sender.
/// @dev The Ethereum owner is immutable and is the only identity the bridge check accepts. There is no direct-call
///      path and the proxy's own ownership can never move: the ownership mutators exist only to revert. To replace
///      a proxy, the DAO transfers ownership of each target contract (for example `Positions.transferOwnership`)
///      to the new proxy through this one.
///      Each bridge message carries one batch of calls that executes atomically, so a proposal sends one message
///      per chain and never depends on the order in which messages are delivered.
abstract contract BridgedOwnerProxy {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error Unauthorized();
    error OwnershipImmutable();
    error InvalidL1Owner();
    error InvalidTarget(uint256 index);
    error InsufficientBalance(uint256 index);
    error CallFailed(uint256 index, bytes data);

    /// @notice Emitted once per executed bridge message. `messageId` is the bridge's id for the message.
    event Executed(bytes32 indexed messageId, uint256 callCount);

    /// @notice The Ethereum address whose bridge messages this proxy executes.
    address public immutable l1Owner;

    constructor(address _l1Owner) {
        if (_l1Owner == address(0)) revert InvalidL1Owner();
        l1Owner = _l1Owner;
    }

    /// @notice Ownable-compatible view. Always the immutable Ethereum owner.
    function owner() external view returns (address) {
        return l1Owner;
    }

    /// @notice Ownable-compatible view. No handover can ever be pending.
    function ownershipHandoverExpiresAt(address) external pure returns (uint256) {
        return 0;
    }

    function transferOwnership(address) external payable {
        revert OwnershipImmutable();
    }

    function renounceOwnership() external payable {
        revert OwnershipImmutable();
    }

    function requestOwnershipHandover() external payable {
        revert OwnershipImmutable();
    }

    function completeOwnershipHandover(address) external payable {
        revert OwnershipImmutable();
    }

    function cancelOwnershipHandover() external payable {
        revert OwnershipImmutable();
    }

    /// @dev Executes every call or none of them. Calls to the proxy itself are rejected.
    function _executeBatch(bytes32 messageId, Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            Call memory c = calls[i];
            if (c.target == address(0) || c.target == address(this)) revert InvalidTarget(i);
            if (address(this).balance < c.value) revert InsufficientBalance(i);

            (bool success, bytes memory result) = c.target.call{value: c.value}(c.data);
            if (!success) revert CallFailed(i, result);
        }
        emit Executed(messageId, calls.length);
    }

    receive() external payable {}
}
