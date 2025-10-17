// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library CommitLib {
    bytes32 public constant EMPTY_COMMIT = keccak256("EMPTY_COMMIT");
    
    struct Commit {
        bytes20 oid;          // 提交唯一标识
        bytes20 tree;         // 树对象OID
        bytes20[] parents;    // 父提交OIDs
        address author;       // 作者地址
        uint256 timestamp;    // 时间戳
        bytes message;        // 提交信息
    }
    
    // 计算提交的哈希值
    function hashCommit(Commit memory commit) internal pure returns (bytes20) {
        return bytes20(keccak256(abi.encode(
            commit.tree,
            commit.parents,
            commit.author,
            commit.timestamp,
            commit.message
        )));
    }
}
