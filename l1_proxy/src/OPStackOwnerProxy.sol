// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {L1L2OwnerProxy} from "./L1L2OwnerProxy.sol";

interface ICrossDomainMessenger {
    function xDomainMessageSender() external view returns (address);
}

contract OPStackOwnerProxy is L1L2OwnerProxy {
    address public constant L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;

    constructor(address initialOwner) L1L2OwnerProxy(initialOwner) {}

    function _isL1Owner() internal view override returns (bool) {
        return msg.sender == L2_CROSS_DOMAIN_MESSENGER
            && ICrossDomainMessenger(L2_CROSS_DOMAIN_MESSENGER).xDomainMessageSender() == owner();
    }

    receive() external payable {}
}
