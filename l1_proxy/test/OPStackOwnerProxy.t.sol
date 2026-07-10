// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {OPStackOwnerProxy} from "../src/OPStackOwnerProxy.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract OPStackTestTarget {
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

contract MockL2CrossDomainMessenger {
    address public xDomainMessageSender;

    function setXDomainMessageSender(address sender) external {
        xDomainMessageSender = sender;
    }
}

contract OPStackOwnerProxyTest is Test {
    address public constant L1_OWNER = address(0x1234);
    address public constant OTHER_L1_OWNER = address(0xbeef);
    address public constant L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;

    OPStackOwnerProxy public proxy;
    OPStackTestTarget public target;

    function setUp() public {
        vm.etch(L2_CROSS_DOMAIN_MESSENGER, address(new MockL2CrossDomainMessenger()).code);

        proxy = new OPStackOwnerProxy(L1_OWNER);
        target = new OPStackTestTarget();
    }

    function test_constructor_sets_l1_owner() public view {
        assertEq(proxy.owner(), L1_OWNER);
        assertEq(proxy.L2_CROSS_DOMAIN_MESSENGER(), L2_CROSS_DOMAIN_MESSENGER);
    }

    function test_constructor_reverts_zero_owner() public {
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        new OPStackOwnerProxy(address(0));
    }

    function test_execute_from_l1_owner_through_l2_messenger() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        bytes memory result =
            proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 123));

        assertEq(abi.decode(result, (uint256)), 124);
        assertEq(target.x(), 123);
    }

    function test_execute_forwards_value() public {
        vm.deal(address(proxy), 1 ether);
        _setXDomainMessageSender(L1_OWNER);

        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(target), 0.25 ether, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 5));

        assertEq(target.x(), 5);
        assertEq(target.received(), 0.25 ether);
        assertEq(address(proxy).balance, 0.75 ether);
    }

    function test_execute_reverts_from_l1_owner_without_messenger() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(L1_OWNER);
        proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_from_messenger_with_wrong_l1_sender() public {
        _setXDomainMessageSender(address(0x4567));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_from_random_address() public {
        address randomAddress = address(0x4567);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(randomAddress);
        proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_invalid_target() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.expectRevert(OPStackOwnerProxy.InvalidTarget.selector);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(0), 0, "");
    }

    function test_execute_reverts_insufficient_balance() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.expectRevert(OPStackOwnerProxy.InsufficientBalance.selector);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(target), 1, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 123));
    }

    function test_execute_reverts_call_failure() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.expectRevert(
            abi.encodeWithSelector(
                OPStackOwnerProxy.CallFailed.selector,
                abi.encodeWithSelector(OPStackTestTarget.RandomError.selector, uint256(0))
            )
        );
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.reverts.selector));
    }

    function test_transfer_ownership_to_new_l1_owner() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.transferOwnership(OTHER_L1_OWNER);

        assertEq(proxy.owner(), OTHER_L1_OWNER);

        _setXDomainMessageSender(L1_OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 1));

        _setXDomainMessageSender(OTHER_L1_OWNER);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.execute(address(target), 0, abi.encodeWithSelector(OPStackTestTarget.setX.selector, 2));
        assertEq(target.x(), 2);
    }

    function test_transfer_ownership_reverts_zero_owner() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.transferOwnership(address(0));
    }

    function test_renounce_ownership_disabled() public {
        _setXDomainMessageSender(L1_OWNER);

        vm.expectRevert(OPStackOwnerProxy.RenounceOwnershipDisabled.selector);
        vm.prank(L2_CROSS_DOMAIN_MESSENGER);
        proxy.renounceOwnership();
    }

    function _setXDomainMessageSender(address sender) internal {
        MockL2CrossDomainMessenger(L2_CROSS_DOMAIN_MESSENGER).setXDomainMessageSender(sender);
    }
}
