// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

/// @notice TEST-ONLY Safe 1.4.1 look-alike for the canceller verification tests (EKU-1217). Same storage layout
///         (slot 0 singleton, 1 modules, 2 owners, 3 ownerCount, 4 threshold, guard / fallback handler slots) and the
///         same `getOwners` / `getThreshold` / `getModulesPaginated` semantics. It has no signers and no signature
///         checks: it is never an approved canceller, and production expectations can never match its runtime.
contract MockSafe {
    address internal constant SENTINEL = address(1);
    bytes32 internal constant GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant FALLBACK_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    bytes32 internal constant MODULE_GUARD_SLOT = 0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;

    address internal singleton;
    mapping(address => address) internal modules;
    mapping(address => address) internal owners;
    uint256 internal ownerCount;
    uint256 internal threshold;

    function setup(address _singleton, address[] memory _owners, uint256 _threshold, address fallbackHandler) external {
        singleton = _singleton;
        modules[SENTINEL] = SENTINEL;
        address cur = SENTINEL;
        for (uint256 i = 0; i < _owners.length; i++) {
            owners[cur] = _owners[i];
            cur = _owners[i];
        }
        owners[cur] = SENTINEL;
        ownerCount = _owners.length;
        threshold = _threshold;
        setSlot(FALLBACK_SLOT, fallbackHandler);
    }

    function setSlot(bytes32 slot, address v) public {
        assembly ("memory-safe") {
            sstore(slot, v)
        }
    }

    function setGuard(address g) external {
        setSlot(GUARD_SLOT, g);
    }

    function setModuleGuard(address g) external {
        setSlot(MODULE_GUARD_SLOT, g);
    }

    function enableModule(address m) external {
        modules[m] = modules[SENTINEL];
        modules[SENTINEL] = m;
    }

    function setThresholdRaw(uint256 t) external {
        threshold = t;
    }

    /// @dev Test-only: forwards a call (e.g. `cancel`) as the Safe would after collecting signatures.
    function exec(address to, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory array) {
        array = new address[](ownerCount);
        uint256 index = 0;
        address cur = owners[SENTINEL];
        while (cur != SENTINEL) {
            array[index] = cur;
            cur = owners[cur];
            index++;
        }
    }

    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next)
    {
        require(start == SENTINEL || modules[start] != address(0), "GS105");
        require(pageSize > 0, "GS106");
        array = new address[](pageSize);
        uint256 moduleCount = 0;
        next = modules[start];
        while (next != address(0) && next != SENTINEL && moduleCount < pageSize) {
            array[moduleCount] = next;
            next = modules[next];
            moduleCount++;
        }
        if (next != SENTINEL) next = array[moduleCount - 1];
        assembly ("memory-safe") {
            mstore(array, moduleCount)
        }
    }
}
