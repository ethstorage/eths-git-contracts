// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {EthfsRepo} from "../src/EthfsRepo.sol";
import {IFlatDirectoryFactory} from "../src/interfaces/IFlatDirectoryFactory.sol";

contract MockFlatDirectoryFactory is IFlatDirectoryFactory {
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

contract EthfsRepoTest is Test {
    EthfsRepo repo;
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
        repo = new EthfsRepo();
        repo.initialize(owner, "myrepo", factory);

        // give roles
        vm.startPrank(owner);
        repo.addMaintainer(maintainer);
        repo.addPusher(pusher);
        vm.stopPrank();
    }

    // ---------------- Basic push ----------------
    function testPushFirstAndSecond() public {
        vm.startPrank(pusher);

        // First push: must have no parent
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);

        (bytes20 head, bool exists) = repo.getBranchHead(BRANCH_MAIN);
        assertTrue(exists);
        assertEq(head, OID1);

        // Second push: must fast-forward
        repo.push(BRANCH_MAIN, OID1, OID2, PACK2, 200);
        (head, exists) = repo.getBranchHead(BRANCH_MAIN);
        assertEq(head, OID2);

        EthfsRepo.PushRecord[] memory recs = repo.getPushRecords(BRANCH_MAIN, 0, 10);
        assertEq(recs.length, 2);
        assertEq(recs[1].newOid, OID2);
        vm.stopPrank();
    }

    // ---------------- Force push: delete branch ----------------
    function testForcePushDeleteDefaultBranchShouldFail() public {
        vm.startPrank(pusher);
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        vm.startPrank(maintainer);
        vm.expectRevert("EthfsRepo: Cannot delete default branch");
        repo.forcePush(BRANCH_MAIN, ZERO_OID, 0x0, 0, ZERO_OID, 0);
        vm.stopPrank();
    }

    function testForcePushDeleteNonDefaultBranch() public {
        // step 1: create default branch first
        vm.startPrank(pusher);
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        // step 2: create another branch
        vm.startPrank(pusher);
        repo.push("dev", ZERO_OID, OID2, PACK2, 200);
        vm.stopPrank();

        (bytes20 headBefore, bool existsBefore) = repo.getBranchHead("dev");
        assertEq(headBefore, OID2);
        assertTrue(existsBefore);

        vm.startPrank(maintainer);
        repo.forcePush("dev", bytes20(0), bytes20(0), 0, bytes20(0), 0);
        vm.stopPrank();

        (bytes20 headAfter, bool existsAfter) = repo.getBranchHead("dev");
        assertEq(headAfter, ZERO_OID);
        assertFalse(existsAfter);
    }

    // ---------------- Force push: full history replace ----------------
    function testForcePushFullHistoryReplace() public {
        vm.startPrank(pusher);
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        repo.push(BRANCH_MAIN, OID1, OID2, PACK2, 200);
        vm.stopPrank();

        vm.startPrank(maintainer);
        // parentOid=0 means full history replace
        repo.forcePush(BRANCH_MAIN, OID3, PACK3, 300, ZERO_OID, 0);
        vm.stopPrank();

        EthfsRepo.PushRecord[] memory recs = repo.getPushRecords(BRANCH_MAIN, 0, 10);
        assertEq(recs.length, 1);
        assertEq(recs[0].newOid, OID3);
        (bytes20 head,) = repo.getBranchHead(BRANCH_MAIN);
        assertEq(head, OID3);
    }

    // ---------------- Force push: partial truncate ----------------
    function testForcePushPartialTruncate() public {
        vm.startPrank(pusher);
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        repo.push(BRANCH_MAIN, OID1, OID2, PACK2, 200);
        vm.stopPrank();

        // parentIndex=0 (keep only first record)
        vm.startPrank(maintainer);
        repo.forcePush(BRANCH_MAIN, OID3, PACK3, 300, OID1, 0);
        vm.stopPrank();

        EthfsRepo.PushRecord[] memory recs = repo.getPushRecords(BRANCH_MAIN, 0, 10);
        assertEq(recs.length, 2);
        assertEq(recs[1].newOid, OID3);
    }

    // ---------------- Branch enumeration ----------------
    function testListBranchesPagination() public {
        vm.startPrank(pusher);
        repo.push("dev", ZERO_OID, OID1, PACK1, 100);
        repo.push("main", ZERO_OID, OID2, PACK2, 100);
        vm.stopPrank();

        EthfsRepo.RefData[] memory list = repo.listBranches(0, 10);
        assertEq(list.length, 2);

        // pagination
        EthfsRepo.RefData[] memory page1 = repo.listBranches(0, 1);
        assertEq(page1.length, 1);
        EthfsRepo.RefData[] memory page2 = repo.listBranches(1, 1);
        assertEq(page2.length, 1);
    }

    // ---------------- Default branch change ----------------
    function testSetDefaultBranch() public {
        vm.startPrank(pusher);
        repo.push("dev", ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        vm.startPrank(maintainer);
        repo.setDefaultBranch("dev");
        (bytes memory name, bytes20 head) = repo.getDefaultBranch();
        assertEq(string(name), "dev");
        assertEq(head, OID1);
        vm.stopPrank();
    }

    // ---------------- Defensive getPushRecords ----------------
    function testGetPushRecordsOutOfRange() public {
        vm.startPrank(pusher);
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        EthfsRepo.PushRecord[] memory recs = repo.getPushRecords(BRANCH_MAIN, 10, 5);
        assertEq(recs.length, 0);
    }

    // ---------------- Fallback proxy path ----------------
    function testFallbackDelegatesToDB() public {
        vm.startPrank(pusher);
        repo.push(BRANCH_MAIN, ZERO_OID, OID1, PACK1, 100);
        vm.stopPrank();

        // call to DB (selector: 0xc1d71b17 for writeChunksByBlobs)
        vm.startPrank(pusher);
        (bool ok, bytes memory ret) = address(repo).call(abi.encodeWithSelector(bytes4(0xc1d71b17)));
        assertTrue(ok);
        assertEq(abi.decode(ret, (string)), "ok");
        vm.stopPrank();
    }
}
