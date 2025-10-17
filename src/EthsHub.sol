// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IFlatDirectoryFactory} from "./interfaces/IFlatDirectoryFactory.sol";

contract EthsHub is Initializable, AccessControlUpgradeable, ReentrancyGuard {
    // Role definitions - Minimum permission set
    bytes32 public constant MAINTAINER_ROLE = keccak256("MAINTAINER_ROLE");
    bytes32 public constant PUSHER_ROLE = keccak256("PUSHER_ROLE");

    // Event definitions - Record key information only
    event RefUpdated(
        bytes32 indexed refKey, bytes refName, bytes20 oldOid, bytes20 newOid, uint256 packfileSize, uint256 timestamp
    );

    event ForceRefUpdated(bytes32 indexed refKey, bytes refName, bytes20 oldOid, bytes20 newOid, uint256 timestamp);

    event DefaultBranchChanged(bytes oldBranch, bytes newBranch);

    // Lightweight Commit Information - Minimal data storage
    struct PushRecord {
        bytes20 newOid; // Final commit oid of the current push
        bytes20 parentOid; // Parent commit oid, used to build history chain
        bytes20 packfileKey; // Key for storing the packfile
        uint256 size; // Packfile size
        uint256 timestamp; // Timestamp
        address pusher; // Pusher address
    }

    // Branch metadata - Minimal storage
    struct Branch {
        bytes20 headOid; // Latest commit oid
        uint256 recordCount; // Number of commit records (for pagination)
        bool exists; // Whether the branch exists
    }

    struct RefData {
        bytes name;
        bytes32 hash;
    }

    // Repository metadata
    bytes public repoName;
    bytes public defaultBranchName;
    address public db; // Address of the database storing packfiles

    // Core storage - Minimal design
    mapping(bytes32 => Branch) private _branches; // refKey => Branch information
    mapping(bytes32 => mapping(uint256 => PushRecord)) private _branchRecords; // refKey => index => Commit record
    bytes[] private _branchNames; // All branch names (for enumeration)

    // Initialization function
    function initialize(address _owner, bytes memory _repoName, IFlatDirectoryFactory _dbFactory) external initializer {
        __AccessControl_init();

        require(_owner != address(0), "EthsHub: Invalid owner");
        require(_repoName.length > 0 && _repoName.length <= 100, "EthsHub: Invalid repo name length");
        for (uint256 i; i < _repoName.length; i++) {
            bytes1 char = _repoName[i];
            require(
                (char >= 0x61 && char <= 0x7A) // a-z
                    || (char >= 0x41 && char <= 0x5A) // A-Z
                    || (char >= 0x30 && char <= 0x39) // 0-9
                    || (char == 0x2D || char == 0x2E || char == 0x5F), // -._
                "EthsHub: Repo name must be alphanumeric or -._"
            );
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(MAINTAINER_ROLE, _owner);
        _grantRole(PUSHER_ROLE, _owner);

        repoName = _repoName;
        db = _dbFactory.create();
    }

    // Permission check modifiers (unwrapped for Gas optimization)
    modifier onlyPusher() {
        _onlyPusher();
        _;
    }

    function _onlyPusher() internal view {
        require(
            hasRole(PUSHER_ROLE, msg.sender) || hasRole(MAINTAINER_ROLE, msg.sender)
                || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "EthsHub: No push permission"
        );
    }

    modifier onlyMaintainer() {
        _onlyMaintainer();
        _;
    }

    function _onlyMaintainer() internal view {
        require(
            hasRole(MAINTAINER_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "EthsHub: No maintainer permission"
        );
    }

    // Permission management: Add pusher
    function addPusher(address account) external onlyMaintainer {
        grantRole(PUSHER_ROLE, account);
    }

    // Permission management: Remove pusher
    function removePusher(address account) external onlyMaintainer {
        revokeRole(PUSHER_ROLE, account);
    }

    // Permission management: Add maintainer
    function addMaintainer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(MAINTAINER_ROLE, account);
    }

    // ---------------------- Query ----------------------
    // Core function: Normal push (fast-forward)
    function push(bytes calldata refName, bytes20 parentOid, bytes20 newOid, bytes20 packfileKey, uint256 packfileSize)
        external
        onlyPusher
        nonReentrant
    {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];

        // First push to this branch
        if (!branch.exists) {
            require(parentOid == bytes20(0), "EthsHub: First push must have no parent");
            branch.headOid = newOid;
            branch.exists = true;
            _branchNames.push(refName);

            // If default branch is not set, set it to the current branch
            if (defaultBranchName.length == 0) {
                defaultBranchName = refName;
            }
        }
        // Subsequent push (must be fast-forward)
        else {
            require(branch.headOid == parentOid, "EthsHub: Non fast-forward push not allowed");
            branch.headOid = newOid;
        }

        // Record push information (store minimal necessary data)
        uint256 recordIndex = branch.recordCount;
        _branchRecords[refKey][recordIndex] = PushRecord({
            newOid: newOid,
            parentOid: parentOid,
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });

        branch.recordCount++;

        emit RefUpdated(refKey, refName, parentOid, newOid, packfileSize, block.timestamp);
    }

    // TODO
    // Force push (Maintainer only)
    function forcePush(
        bytes calldata refName,
        bytes20 newOid,
        bytes20 packfileKey,
        uint256 packfileSize,
        bytes20 parentOid // Parent node of the new commit (may not be in the current branch history)
    ) external onlyMaintainer nonReentrant {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];

        require(branch.exists, "EthsHub: Branch does not exist");

        bytes20 oldOid = branch.headOid;
        // Update branch head
        branch.headOid = newOid;

        // Record force push (marked as a special record)
        uint256 recordIndex = branch.recordCount;
        _branchRecords[refKey][recordIndex] = PushRecord({
            newOid: newOid,
            parentOid: parentOid, // Stored as the parent of the new commit, not the original branch head
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });

        branch.recordCount++;

        emit ForceRefUpdated(refKey, refName, oldOid, newOid, block.timestamp);
    }

    // Set default branch
    function setDefaultBranch(bytes calldata branchName) external onlyMaintainer {
        bytes32 key = _keccak256(branchName);
        require(_branches[key].exists, "EthsHub: Branch not exists");

        bytes memory oldBranch = defaultBranchName;
        defaultBranchName = branchName;

        emit DefaultBranchChanged(oldBranch, branchName);
    }

    // ---------------------- Query ----------------------
    // Query function: Get branch list (paginated)
    function listBranches(uint256 start, uint256 limit) external view returns (RefData[] memory list) {
        uint256 end = start + limit;
        if (end > _branchNames.length) {
            end = _branchNames.length;
        }

        uint256 count = end > start ? end - start : 0;
        list = new RefData[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes memory branchName = _branchNames[start + i];
            bytes32 key = _keccak256(branchName);
            list[i] = RefData({name: branchName, hash: _branches[key].headOid});
        }
    }

    // Query function: Get total branch count
    function getBranchCount() external view returns (uint256) {
        return _branchNames.length;
    }

    // Query function: Get default branch
    function getDefaultBranch() external view returns (bytes memory name, bytes20 headOid) {
        return (defaultBranchName, _branches[_keccak256(defaultBranchName)].headOid);
    }

    // Query function: Get branch head info
    function getBranchHead(bytes calldata refName) external view returns (bytes20 headOid, bool exists) {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        return (branch.headOid, branch.exists);
    }

    // Query function: Get push records (for efficient history fetching)
    function getPushRecords(bytes calldata refName, uint256 startIndex, uint256 count)
        external
        view
        returns (PushRecord[] memory)
    {
        bytes32 refKey = _keccak256(refName); // Note: Already optimized by the helper function
        Branch storage branch = _branches[refKey];
        require(branch.exists, "EthsHub: Branch not exists");

        uint256 endIndex = startIndex + count;
        if (endIndex > branch.recordCount) {
            endIndex = branch.recordCount;
        }

        uint256 resultCount = endIndex > startIndex ? endIndex - startIndex : 0;
        PushRecord[] memory results = new PushRecord[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            results[i] = _branchRecords[refKey][startIndex + i];
        }
        return results;
    }

    // ---------------------- Database fallback ----------------------

    // Database interaction proxy (forward necessary calls only)
    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes4 selector;
        assembly {
            selector := calldataload(0)
        }

        // write check
        if (
            selector == 0xc1d71b17 // writeChunksByBlobs
                || selector == 0x6c0a0207 // remove
                || selector == 0x4d705e59 // truncate
        ) {
            require(
                hasRole(PUSHER_ROLE, msg.sender) || hasRole(MAINTAINER_ROLE, msg.sender)
                    || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
                "EthsHub: No write permission"
            );
        }

        (bool success, bytes memory result) = db.call{value: msg.value}(data);
        if (!success) {
            // Revert with the returned data from the call (standard pattern)
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }

    receive() external payable {}

    // ---------------------- Internal Helpers ----------------------

    /**
     * @dev Gas-optimized keccak256 hash using inline assembly.
     * @param data The bytes array to hash.
     * @return result The 32-byte hash.
     */
    function _keccak256(bytes memory data) internal pure returns (bytes32 result) {
        // The KECCAK256 opcode is used directly via assembly, which is more
        // gas-efficient than the Solidity builtin function for dynamic data.
        assembly {
            // data is at p; data length is mload(data)
            // Actual content starts 32 bytes after the pointer (skipping the length)
            result := keccak256(add(data, 32), mload(data))
        }
    }
}
