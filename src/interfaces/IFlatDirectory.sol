// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IFlatDirectory {
    function writeChunksByBlobs(bytes calldata data, uint256[] calldata offsets, uint256[] calldata lengths) external;
    function remove(bytes calldata key) external;
    function truncate(bytes calldata key, uint256 length) external;
    function read(bytes calldata key) external view returns (bytes memory);
    function size(bytes calldata key) external view returns (uint256);
    function exists(bytes calldata key) external view returns (bool);
}
