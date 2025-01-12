// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";

contract MockStarknetMessaging is IStarknetMessaging {
    mapping(bytes32 => uint256) public messageCount;

    function getMessageHash(uint256 fromAddress, uint256[] calldata payload) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(fromAddress, payload));
    }

    function setMessageCount(uint256 fromAddress, uint256[] calldata payload, uint256 count) external {
        messageCount[getMessageHash(fromAddress, payload)] = count;
    }

    function consumeMessageFromL2(uint256 fromAddress, uint256[] calldata payload) external returns (bytes32) {
        bytes32 messageHash = getMessageHash(fromAddress, payload);
        messageCount[messageHash]--;
        return messageHash;
    }
}

contract TestTarget {
    uint256 public x;

    error RandomError(uint256 x);

    function setX(uint256 _x) external {
        x = _x;
    }

    function reverts() external view {
        revert RandomError(x);
    }
}

contract StarknetOwnerProxyTest is Test {
    uint256 public l2Owner;
    MockStarknetMessaging public messaging;
    StarknetOwnerProxy public proxy;
    TestTarget public target;

    function setUp() public {
        l2Owner = 0xabcdabcdabcd;
        messaging = new MockStarknetMessaging();
        proxy = new StarknetOwnerProxy(messaging, l2Owner);
        target = new TestTarget();
    }

    function test_get_payload_empty() public view {
        uint256[] memory expected = new uint256[](4);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 5;
        expected[3] = 0;
        assertEq(proxy.getPayload(address(0xdeadbeef), 123, 5, hex""), expected);
    }

    function test_get_payload_one_partial_word() public view {
        uint256[] memory expected = new uint256[](5);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 12;
        expected[3] = 3;
        expected[4] = 0xabcdef << 224;
        assertEq(proxy.getPayload(address(0xdeadbeef), 123, 12, hex"abcdef"), expected);
    }

    function test_get_payload_31_bytes() public view {
        uint256[] memory expected = new uint256[](5);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 79;
        expected[3] = 31;
        expected[4] = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        assertEq(
            proxy.getPayload(
                address(0xdeadbeef), 123, 79, hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            ),
            expected
        );
    }

    function test_get_payload_32_bytes() public view {
        uint256[] memory expected = new uint256[](6);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 555;
        expected[3] = 32;
        expected[4] = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        expected[5] = 0xff000000000000000000000000000000000000000000000000000000000000;

        assertEq(
            proxy.getPayload(
                address(0xdeadbeef), 123, 555, hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            ),
            expected
        );
    }

    function test_get_payload_62_bytes() public view {
        uint256[] memory expected = new uint256[](6);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 2332;
        expected[3] = 62;
        expected[4] = 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd;
        expected[5] = 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd;

        assertEq(
            proxy.getPayload(
                address(0xdeadbeef),
                123,
                2332,
                hex"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
            ),
            expected
        );
    }

    function test_get_payload_64_bytes() public view {
        uint256[] memory expected = new uint256[](7);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 9009;
        expected[3] = 64;
        expected[4] = 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd;
        expected[5] = 0xef0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab;
        expected[6] = 0xcdef << 232;

        assertEq(
            proxy.getPayload(
                address(0xdeadbeef),
                123,
                9009,
                hex"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ),
            expected
        );
    }

    function test_execute() external {
        uint256[] memory payload =
            proxy.getPayload(address(target), 0, 0, abi.encodeWithSelector(TestTarget.setX.selector, (123)));

        messaging.setMessageCount(l2Owner, payload, 1);
        assertEq(target.x(), 0);
        proxy.execute(address(target), 0, 0, abi.encodeWithSelector(TestTarget.setX.selector, (123)));
        assertEq(target.x(), 123);
    }

    function test_execute_twice_fails_nonce() external {
        uint256[] memory payload =
            proxy.getPayload(address(target), 0, 0, abi.encodeWithSelector(TestTarget.setX.selector, (123)));

        // theoretically it could consume the message twice, but it doesn't due to the nonce check
        messaging.setMessageCount(l2Owner, payload, 2);
        assertEq(target.x(), 0);
        proxy.execute(address(target), 0, 0, abi.encodeWithSelector(TestTarget.setX.selector, (123)));
        vm.expectRevert(
            abi.encodeWithSelector(StarknetOwnerProxy.InvalidNonce.selector, uint64(1), uint64(0)), address(proxy)
        );
        proxy.execute(address(target), 0, 0, abi.encodeWithSelector(TestTarget.setX.selector, (123)));
    }

    function test_execute_fails_no_message() external {
        vm.expectRevert(address(messaging));
        proxy.execute(address(target), 0, 0, abi.encodeWithSelector(TestTarget.setX.selector, (123)));
    }

    function test_execute_call_fails() external {
        uint256[] memory payload =
            proxy.getPayload(address(target), 0, 0, abi.encodeWithSelector(TestTarget.reverts.selector));

        messaging.setMessageCount(l2Owner, payload, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                StarknetOwnerProxy.CallFailed.selector,
                abi.encodeWithSelector(TestTarget.RandomError.selector, uint256(0))
            )
        );
        proxy.execute(address(target), 0, 0, abi.encodeWithSelector(TestTarget.reverts.selector));
    }
}
