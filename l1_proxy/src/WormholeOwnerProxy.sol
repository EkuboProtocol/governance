// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {L1L2OwnerProxy} from "./L1L2OwnerProxy.sol";

interface IWormhole {
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }

    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }

    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VM memory vm, bool valid, string memory reason);
}

/// @notice SKETCH (EKU-1033): owner proxy for chains with no Ethereum-anchored canonical bridge (BNB, Monad).
/// @dev The Ethereum owner (the L1 DAO proxy) calls Wormhole.publishMessage(nonce, payload, 1 /* finalized */) itself,
///      so it is the VAA emitter; anyone may then relay the signed VAA here. A VAA is valid on every chain, so the
///      payload binds the destination chain id and this proxy's address. Emitter sequences must strictly increase, which
///      blocks replay and stops an older, unexecuted message from running after a newer one.
contract WormholeOwnerProxy is L1L2OwnerProxy {
    error InvalidVAA(string reason);
    error WrongEmitter();
    error WrongDestination();
    error NotFinalized();
    error StaleSequence(uint64 nextSequence, uint64 sequence);
    error Expired(uint64 deadline);

    IWormhole public immutable wormhole;
    uint16 public immutable emitterChainId;

    uint64 public nextSequence;

    constructor(address initialOwner, IWormhole _wormhole, uint16 _emitterChainId) L1L2OwnerProxy(initialOwner) {
        wormhole = _wormhole;
        emitterChainId = _emitterChainId;
    }

    function receiveMessage(bytes calldata encodedVM) external returns (bytes memory) {
        (IWormhole.VM memory vm, bool valid, string memory reason) = wormhole.parseAndVerifyVM(encodedVM);
        if (!valid) revert InvalidVAA(reason);
        if (vm.emitterChainId != emitterChainId || vm.emitterAddress != bytes32(uint256(uint160(owner())))) {
            revert WrongEmitter();
        }
        if (vm.consistencyLevel != 1) revert NotFinalized();
        if (vm.sequence < nextSequence) revert StaleSequence(nextSequence, vm.sequence);
        nextSequence = vm.sequence + 1;

        (uint256 chainId, address proxy, address target, uint256 value, bytes memory data, uint64 deadline) =
            abi.decode(vm.payload, (uint256, address, address, uint256, bytes, uint64));
        if (chainId != block.chainid || proxy != address(this)) revert WrongDestination();
        if (block.timestamp > deadline) revert Expired(deadline);

        return this.execute(target, value, data);
    }

    function _isL1Owner() internal view override returns (bool) {
        return msg.sender == address(this);
    }

    receive() external payable {}
}
