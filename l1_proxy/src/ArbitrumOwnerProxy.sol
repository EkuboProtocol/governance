// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

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

contract ArbitrumOwnerProxy is Ownable {
    error InvalidTarget();
    error InsufficientBalance();
    error RenounceOwnershipDisabled();
    error CallFailed(bytes data);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert NewOwnerIsZeroAddress();
        _initializeOwner(initialOwner);
    }

    function l2OwnerAlias() public view returns (address) {
        return ArbitrumAddressAliasHelper.applyL1ToL2Alias(owner());
    }

    function execute(address target, uint256 value, bytes calldata data) external onlyOwner returns (bytes memory) {
        if (target == address(0)) revert InvalidTarget();
        if (address(this).balance < value) revert InsufficientBalance();

        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
        return result;
    }

    function renounceOwnership() public payable override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function _checkOwner() internal view override {
        if (msg.sender != l2OwnerAlias()) revert Unauthorized();
    }

    receive() external payable {}
}
