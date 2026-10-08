// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {L1L2OwnerProxy} from "./L1L2OwnerProxy.sol";

/// @notice Owner proxy for Polygon PoS, controlled from Ethereum through FxPortal (state sync).
/// @dev The Ethereum owner calls FxRoot.sendMessageToChild(proxy, abi.encode(target, value, data, deadline)).
///      FxChild then calls processMessageFromRoot(stateId, rootMessageSender, message), where rootMessageSender is
///      the msg.sender seen by FxRoot. A reverted delivery is stored by StateReceiver and can be replayed by anyone
///      (PIP-36 replayFailedStateSync), so every message carries a deadline after which it can no longer execute.
contract FxPortalOwnerProxy is L1L2OwnerProxy {
    error Expired(uint64 deadline);

    address public immutable fxChild;

    constructor(address initialOwner, address _fxChild) L1L2OwnerProxy(initialOwner) {
        fxChild = _fxChild;
    }

    function processMessageFromRoot(uint256, address rootMessageSender, bytes calldata message) external {
        if (msg.sender != fxChild || rootMessageSender != owner()) revert Unauthorized();
        (address target, uint256 value, bytes memory data, uint64 deadline) =
            abi.decode(message, (address, uint256, bytes, uint64));
        if (block.timestamp > deadline) revert Expired(deadline);
        // Self-call so the owner-gated execute (and transferOwnership via target == this) see msg.sender == this.
        this.execute(target, value, data);
    }

    function _isL1Owner() internal view override returns (bool) {
        return msg.sender == address(this);
    }

    receive() external payable {}
}
