// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbitrumAddressAliasHelper, ArbitrumOwnerProxy} from "../src/ArbitrumOwnerProxy.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract ArbitrumTestTarget {
    uint256 public x;
    uint256 public received;

    error RandomError(uint256 x);

    function setX(uint256 _x) external payable returns (uint256) {
        x = _x;
        received += msg.value;
        return _x + 1;
    }

    function reverts() external view {
        revert RandomError(x);
    }
}

contract ArbitrumOwnerProxyTest is Test {
    address public constant L1_OWNER = address(0x1234);
    address public constant OTHER_L1_OWNER = address(0xbeef);

    ArbitrumOwnerProxy public proxy;
    ArbitrumTestTarget public target;

    function setUp() public {
        proxy = new ArbitrumOwnerProxy(L1_OWNER);
        target = new ArbitrumTestTarget();
    }

    function test_constructor_sets_l1_owner() public view {
        assertEq(proxy.owner(), L1_OWNER);
        assertEq(proxy.l2OwnerAlias(), address(0x1111000000000000000000000000000000002345));
    }

    function test_constructor_reverts_zero_owner() public {
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        new ArbitrumOwnerProxy(address(0));
    }

    function test_execute_from_l1_owner_alias() public {
        vm.prank(proxy.l2OwnerAlias());
        bytes memory result =
            proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 123));

        assertEq(abi.decode(result, (uint256)), 124);
        assertEq(target.x(), 123);
    }

    function test_execute_forwards_value() public {
        vm.deal(address(proxy), 1 ether);

        vm.prank(proxy.l2OwnerAlias());
        proxy.execute(address(target), 0.25 ether, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 5));

        assertEq(target.x(), 5);
        assertEq(target.received(), 0.25 ether);
        assertEq(address(proxy).balance, 0.75 ether);
    }

    function test_execute_reverts_from_l1_owner_without_alias() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(L1_OWNER);
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_from_random_address() public {
        address randomAddress = address(0x4567);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(randomAddress);
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_invalid_target() public {
        address ownerAlias = proxy.l2OwnerAlias();

        vm.expectRevert(ArbitrumOwnerProxy.InvalidTarget.selector);
        vm.prank(ownerAlias);
        proxy.execute(address(0), 0, "");
    }

    function test_execute_reverts_insufficient_balance() public {
        address ownerAlias = proxy.l2OwnerAlias();

        vm.expectRevert(ArbitrumOwnerProxy.InsufficientBalance.selector);
        vm.prank(ownerAlias);
        proxy.execute(address(target), 1, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_call_failure() public {
        address ownerAlias = proxy.l2OwnerAlias();

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrumOwnerProxy.CallFailed.selector,
                abi.encodeWithSelector(ArbitrumTestTarget.RandomError.selector, uint256(0))
            )
        );
        vm.prank(ownerAlias);
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.reverts.selector));
    }

    function test_transfer_ownership_to_new_l1_owner() public {
        address oldAlias = proxy.l2OwnerAlias();

        vm.prank(oldAlias);
        proxy.transferOwnership(OTHER_L1_OWNER);

        assertEq(proxy.owner(), OTHER_L1_OWNER);
        assertEq(proxy.l2OwnerAlias(), ArbitrumAddressAliasHelper.applyL1ToL2Alias(OTHER_L1_OWNER));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(oldAlias);
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 1));

        vm.prank(proxy.l2OwnerAlias());
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 2));
        assertEq(target.x(), 2);
    }

    function test_transfer_ownership_reverts_zero_owner() public {
        address ownerAlias = proxy.l2OwnerAlias();

        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        vm.prank(ownerAlias);
        proxy.transferOwnership(address(0));
    }

    function test_complete_ownership_handover_stores_unaliased_l1_owner() public {
        address oldAlias = proxy.l2OwnerAlias();
        address newAlias = ArbitrumAddressAliasHelper.applyL1ToL2Alias(OTHER_L1_OWNER);

        vm.prank(newAlias);
        proxy.requestOwnershipHandover();

        vm.prank(oldAlias);
        proxy.completeOwnershipHandover(newAlias);

        assertEq(proxy.owner(), OTHER_L1_OWNER);
        assertEq(proxy.l2OwnerAlias(), newAlias);
        assertEq(proxy.ownershipHandoverExpiresAt(newAlias), 0);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(oldAlias);
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 1));

        vm.prank(newAlias);
        proxy.execute(address(target), 0, abi.encodeWithSelector(ArbitrumTestTarget.setX.selector, 2));
        assertEq(target.x(), 2);
    }

    function test_renounce_ownership_disabled() public {
        address ownerAlias = proxy.l2OwnerAlias();

        vm.expectRevert(ArbitrumOwnerProxy.RenounceOwnershipDisabled.selector);
        vm.prank(ownerAlias);
        proxy.renounceOwnership();
    }
}
