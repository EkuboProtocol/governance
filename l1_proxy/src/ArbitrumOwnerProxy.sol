// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {L1L2OwnerProxy} from "./L1L2OwnerProxy.sol";

library ArbitrumAddressAliasHelper {
    uint160 internal constant OFFSET = uint160(0x1111000000000000000000000000000000001111);

    function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + OFFSET);
        }
    }

    function undoL1ToL2Alias(address l2Address) internal pure returns (address l1Address) {
        unchecked {
            l1Address = address(uint160(l2Address) - OFFSET);
        }
    }
}

contract ArbitrumOwnerProxy is L1L2OwnerProxy {
    constructor(address initialOwner) L1L2OwnerProxy(initialOwner) {}

    function l2OwnerAlias() public view returns (address) {
        return ArbitrumAddressAliasHelper.applyL1ToL2Alias(owner());
    }

    function _isL1Owner() internal view override returns (bool) {
        return msg.sender == l2OwnerAlias();
    }

    receive() external payable {}
}
