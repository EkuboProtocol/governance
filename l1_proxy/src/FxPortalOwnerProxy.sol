// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BridgedOwnerProxy} from "./BridgedOwnerProxy.sol";

/// @notice Owner proxy for Polygon PoS, controlled from Ethereum through FxPortal (state sync).
/// @dev The Ethereum owner calls FxRoot.sendMessageToChild(proxy, abi.encode(calls, deadline)). FxChild then calls
///      processMessageFromRoot(stateId, rootMessageSender, message), where rootMessageSender is the msg.sender seen
///      by FxRoot and stateId is the StateSender counter, which increases with every state sync on Ethereum.
///      A delivery that reverts is stored by StateReceiver and anyone can replay it later (PIP-36,
///      replayFailedStateSync). Two rules bound that:
///      - a message only executes if its stateId is above that of every message executed before, so a stored
///        failure can never run after a newer DAO message (and a newer message, even with no calls, supersedes it);
///      - a message never executes after its deadline. Proposals set the deadline no more than 14 days after the
///        Ethereum send.
contract FxPortalOwnerProxy is BridgedOwnerProxy {
    error StaleStateId(uint256 stateId, uint256 lastStateId);
    error Expired(uint64 deadline);

    address public immutable fxChild;

    /// @notice stateId of the last message executed.
    uint256 public lastStateId;

    constructor(address _l1Owner, address _fxChild) BridgedOwnerProxy(_l1Owner) {
        fxChild = _fxChild;
    }

    function processMessageFromRoot(uint256 stateId, address rootMessageSender, bytes calldata message) external {
        if (msg.sender != fxChild || rootMessageSender != l1Owner) revert Unauthorized();
        if (stateId <= lastStateId) revert StaleStateId(stateId, lastStateId);
        (Call[] memory calls, uint64 deadline) = abi.decode(message, (Call[], uint64));
        if (block.timestamp > deadline) revert Expired(deadline);

        lastStateId = stateId;
        _executeBatch(bytes32(stateId), calls);
    }
}
