// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BridgedOwnerProxy} from "./BridgedOwnerProxy.sol";

interface IAMB {
    function messageSender() external view returns (address);
    function messageSourceChainId() external view returns (bytes32);
    function messageId() external view returns (bytes32);
}

/// @notice Owner proxy for Gnosis Chain, controlled from Ethereum through the canonical Arbitrary Message Bridge.
/// @dev The Ethereum owner calls ForeignAMB.requireToPassMessage(proxy, abi.encodeCall(executeBatch, (calls)), gas).
///      After the validators affirm the message, HomeAMB calls executeBatch with msg.sender == HomeAMB,
///      messageSender() == the Ethereum caller and messageSourceChainId() == 1. HomeAMB marks a message processed
///      whether or not the call succeeds and never runs it again, so a failed message is final; the DAO sends a new
///      one. Send exactly one message per chain per proposal: validators affirm messages independently, so the
///      delivery order of two messages is not guaranteed.
contract AMBOwnerProxy is BridgedOwnerProxy {
    IAMB public immutable amb;
    bytes32 public immutable sourceChainId;

    constructor(address _l1Owner, IAMB _amb, uint256 _sourceChainId) BridgedOwnerProxy(_l1Owner) {
        amb = _amb;
        sourceChainId = bytes32(_sourceChainId);
    }

    function executeBatch(Call[] calldata calls) external {
        if (msg.sender != address(amb) || amb.messageSender() != l1Owner || amb.messageSourceChainId() != sourceChainId)
        {
            revert Unauthorized();
        }
        _executeBatch(amb.messageId(), calls);
    }
}
