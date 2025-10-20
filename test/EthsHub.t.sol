// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {EthsHub} from "../src/EthsHub.sol";
import {IFlatDirectoryFactory} from "../src/interfaces/IFlatDirectoryFactory.sol";

contract MockFlatDirectoryFactory is IFlatDirectoryFactory{
    address public created;

    function create() external returns (address) {
        created = address(new MockDB());
        return created;
    }
}

contract MockDB {
    // allow arbitrary fallback call
    fallback(bytes calldata data) external payable returns (bytes memory) {
        console.logBytes(data);
        return abi.encode("ok");
    }
}

contract EthsHubTest is Test {
    EthsHub hub;
    MockFlatDirectoryFactory factory;
    address owner = address(0x1);
    address maintainer = address(0x2);
    address pusher = address(0x3);

    bytes constant BRANCH_MAIN = "main";
    bytes20 constant ZERO_OID = bytes20(0);
    bytes20 constant OID1 = bytes20(uint160(0x1111));
    bytes20 constant OID2 = bytes20(uint160(0x2222));
    bytes20 constant OID3 = bytes20(uint160(0x3333));
    bytes20 constant PACK1 = bytes20(uint160(0xAAAA));
    bytes20 constant PACK2 = bytes20(uint160(0xBBBB));
    bytes20 constant PACK3 = bytes20(uint160(0xCCCC));

    function setUp() public {
        factory = new MockFlatDirectoryFactory();
        hub = new EthsHub();
        hub.initialize(owner, "myrepo", factory);

        // give roles
        vm.startPrank(owner);
        hub.addMaintainer(maintainer);
        hub.addPusher(pusher);
        vm.stopPrank();
    }

    // ---------------- Basic push ----------------
    function testPushFirstAndSecond() public {
        vm.startPrank(pusher);

        // First push: must have no parent
        hub.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);

        (bytes20 head, bool exists) = hub.getBranchHead(BRANCH_MAIN);
        assertTrue(exists);
        assertEq(head, OID1);

        // Second push: must fast-forward
        hub.push(BRANCH_MAIN, OID1, OID2, PACK2, 200);
        (head, exists) = hub.getBranchHead(BRANCH_MAIN);
        assertEq(head, OID2);

        EthsHub.PushRecord[] memory recs = hub.getPushRecords(BRANCH_MAIN, 0, 10);
        assertEq(recs.length, 2);
        assertEq(recs[1].newOid, OID2);
        vm.stopPrank();
    }

    // ---------------- Force push: delete branch ----------------
    function testForcePushDeleteBranch() public {
        vm.startPrank(pusher);
        hub.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        vm.startPrank(maintainer);
        hub.forcePush(BRANCH_MAIN, ZERO_OID, 0x0, 0, ZERO_OID, 0); // delete branch

        (bytes20 head, bool exists) = hub.getBranchHead(BRANCH_MAIN);
        assertEq(head, ZERO_OID);
        assertFalse(exists);
        assertEq(hub.getBranchCount(), 0);
        vm.stopPrank();
    }

    // ---------------- Force push: full history replace ----------------
    function testForcePushFullHistoryReplace() public {
        vm.startPrank(pusher);
        hub.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        hub.push(BRANCH_MAIN, OID1, OID2, PACK2, 200);
        vm.stopPrank();

        vm.startPrank(maintainer);
        // parentOid=0 means full history replace
        hub.forcePush(BRANCH_MAIN, OID3, PACK3, 300, ZERO_OID, 0);
        vm.stopPrank();

        EthsHub.PushRecord[] memory recs = hub.getPushRecords(BRANCH_MAIN, 0, 10);
        assertEq(recs.length, 1);
        assertEq(recs[0].newOid, OID3);
        (bytes20 head,) = hub.getBranchHead(BRANCH_MAIN);
        assertEq(head, OID3);
    }

    // ---------------- Force push: partial truncate ----------------
    function testForcePushPartialTruncate() public {
        vm.startPrank(pusher);
        hub.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        hub.push(BRANCH_MAIN, OID1, OID2, PACK2, 200);
        vm.stopPrank();

        // parentIndex=0 (keep only first record)
        vm.startPrank(maintainer);
        hub.forcePush(BRANCH_MAIN, OID3, PACK3, 300, OID1, 0);
        vm.stopPrank();

        EthsHub.PushRecord[] memory recs = hub.getPushRecords(BRANCH_MAIN, 0, 10);
        assertEq(recs.length, 2);
        assertEq(recs[1].newOid, OID3);
    }

    // ---------------- Branch enumeration ----------------
    function testListBranchesPagination() public {
        vm.startPrank(pusher);
        hub.push("dev", ZERO_OID, OID1, PACK1, 100);
        hub.push("main", ZERO_OID, OID2, PACK2, 100);
        vm.stopPrank();

        EthsHub.RefData[] memory list = hub.listBranches(0, 10);
        assertEq(list.length, 2);

        // pagination
        EthsHub.RefData[] memory page1 = hub.listBranches(0, 1);
        assertEq(page1.length, 1);
        EthsHub.RefData[] memory page2 = hub.listBranches(1, 1);
        assertEq(page2.length, 1);
    }

    // ---------------- Default branch change ----------------
    function testSetDefaultBranch() public {
        vm.startPrank(pusher);
        hub.push("dev", ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        vm.startPrank(maintainer);
        hub.setDefaultBranch("dev");
        (bytes memory name, bytes20 head) = hub.getDefaultBranch();
        assertEq(string(name), "dev");
        assertEq(head, OID1);
        vm.stopPrank();
    }

    // ---------------- Defensive getPushRecords ----------------
    function testGetPushRecordsOutOfRange() public {
        vm.startPrank(pusher);
        hub.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        EthsHub.PushRecord[] memory recs = hub.getPushRecords(BRANCH_MAIN, 10, 5);
        assertEq(recs.length, 0);
    }

    // ---------------- Fallback proxy path ----------------
    function testFallbackDelegatesToDB() public {
        vm.startPrank(pusher);
        hub.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        // call to DB (selector: 0xc1d71b17 for writeChunksByBlobs)
        vm.startPrank(pusher);
        (bool ok, bytes memory ret) = address(hub).call(abi.encodeWithSelector(bytes4(0xc1d71b17)));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "ok");
        vm.stopPrank();
    }
}
