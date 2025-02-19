// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

interface IStarknetMessaging {
    function consumeMessageFromL2(uint256 fromAddress, uint256[] calldata payload) external returns (bytes32);
}

contract StarknetOwnerProxy {
    error InvalidTarget();
    error InsufficientBalance();
    error InvalidNonce(uint64 current, uint64 nonce);
    error CallFailed(bytes data);

    IStarknetMessaging public immutable l2MessageBridge;
    uint256 public immutable l2Owner;

    uint64 public currentNonce;

    constructor(IStarknetMessaging _l2MessageBridge, uint256 _l2Owner) {
        l2MessageBridge = _l2MessageBridge;
        l2Owner = _l2Owner;
    }

    // Returns the payload split into 31-byte chunks,
    // ensuring each element is < 2^251
    function getPayload(address target, uint256 value, uint64 nonce, bytes calldata data)
        public
        pure
        returns (uint256[] memory)
    {
        // Each payload element can hold up to 31 bytes since it has to be expressed as felt252 on Starknet
        uint256 chunkCount = (data.length + 30) / 31;
        uint256[] memory payload = new uint256[](4 + chunkCount);

        payload[0] = uint256(uint160(target));
        payload[1] = value;
        payload[2] = nonce;
        payload[3] = data.length;

        for (uint256 i = 0; i < chunkCount; i++) {
            assembly ("memory-safe") {
                mstore(add(payload, mul(add(i, 5), 32)), shr(8, calldataload(add(data.offset, mul(i, 31)))))
            }
        }

        return payload;
    }

    function execute(address target, uint256 value, uint64 nonce, bytes calldata data)
        external
        returns (bytes memory)
    {
        if (target == address(0) || target == address(this)) {
            revert InvalidTarget();
        }
        if (address(this).balance < value) revert InsufficientBalance();

        if (currentNonce != nonce) revert InvalidNonce(currentNonce, nonce);
        currentNonce++;

        // Consume message from L2. This will fail if the message has not been sent from L2.
        l2MessageBridge.consumeMessageFromL2(l2Owner, getPayload(target, value, nonce, data));

        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
        return result;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
