// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {L1L2OwnerProxy} from "./L1L2OwnerProxy.sol";

interface IAMB {
    function messageSender() external view returns (address);
    function messageSourceChainId() external view returns (bytes32);
}

/// @notice Owner proxy for Gnosis Chain, controlled from Ethereum through the canonical Arbitrary Message Bridge.
/// @dev The Ethereum owner calls ForeignAMB.requireToPassMessage(proxy, abi.encodeCall(execute, (...)), gas);
///      the HomeAMB then calls execute with msg.sender == HomeAMB and messageSender() == the Ethereum caller.
contract AMBOwnerProxy is L1L2OwnerProxy {
    IAMB public immutable amb;
    bytes32 public immutable sourceChainId;

    constructor(address initialOwner, IAMB _amb, uint256 _sourceChainId) L1L2OwnerProxy(initialOwner) {
        amb = _amb;
        sourceChainId = bytes32(_sourceChainId);
    }

    function _isL1Owner() internal view override returns (bool) {
        return msg.sender == address(amb) && amb.messageSender() == owner()
            && amb.messageSourceChainId() == sourceChainId;
    }

    receive() external payable {}
}
