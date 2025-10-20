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
    event BranchDeleted(bytes refName, uint256 timestamp);
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

    // Branch Metadata (Core: activeLength maintains the logical number of valid records)
    struct Branch {
        bytes20 headOid; // Latest commit oid of the branch
        uint256 activeLength; // Logical count of valid records (core field, replaces array length)
        bool exists; // Whether the branch exists
    }

    // Branch list query return structure
    struct RefData {
        bytes name; // Branch name
        bytes20 hash; // Latest commit oid of the branch
    }

    // ======================== Core Storage ========================
    // Repository metadata
    bytes public repoName;
    bytes public defaultBranchName;
    address public db; // Address of the database storing packfiles

    // Branch mapping: refKey (hash of branch name) → Branch info
    mapping(bytes32 => Branch) private _branches; // refKey => Branch information
    // Push Record mapping: refKey → Physical Array (data is never deleted, filtered by activeLength)
    mapping(bytes32 => PushRecord[]) private _branchRecords;

    bytes[] private _branchNames; // All branch names (for enumeration)
    // Branch Name Index mapping: Quick lookup of branch name's position in _branchNames (used for deletion)
    mapping(bytes32 => uint256) private _branchNameIndex;

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

    // ======================== Permission check modifiers ========================
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

    // ======================== Permission management ========================
    function addPusher(address account) external onlyMaintainer {
        grantRole(PUSHER_ROLE, account);
    }

    function removePusher(address account) external onlyMaintainer {
        revokeRole(PUSHER_ROLE, account);
    }

    function addMaintainer(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(MAINTAINER_ROLE, account);
    }

    // ======================== Core Business Functions ========================
    /**
     * @dev Normal push (fast-forward)
     * Core: Uses indexed assignment instead of push, marks valid records via activeLength.
     */
    function push(bytes calldata refName, bytes20 parentOid, bytes20 newOid, bytes20 packfileKey, uint256 packfileSize)
        external
        onlyPusher
        nonReentrant
    {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        PushRecord[] storage records = _branchRecords[refKey]; // Reference to the physical array

        // 1. First push to this branch
        if (!branch.exists) {
            require(parentOid == bytes20(0), "EthsHub: First push must have no parent");
            branch.headOid = newOid;
            branch.exists = true;
            branch.activeLength = 0; // Initial active length is 0 (no valid records yet)

            // Record branch name and index
            _branchNameIndex[refKey] = _branchNames.length;
            _branchNames.push(refName);

            // If default branch is not set, set it to the current branch
            if (defaultBranchName.length == 0) {
                defaultBranchName = refName;
            }
        }
        // 2. Subsequent push (must be fast-forward: Parent OID must match current branch head)
        else {
            require(branch.headOid == parentOid, "EthsHub: Non fast-forward push not allowed");
            branch.headOid = newOid;
        }

        // 3. Core: Use indexed assignment instead of push, do not modify physical array length explicitly
        // Assign to the index corresponding to the "current active length" (physical array auto-expands if needed)
        PushRecord memory newRecord = PushRecord({
            newOid: newOid,
            parentOid: parentOid,
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });
        _writeRecord(records, branch.activeLength, newRecord);
        // Increment logical active length (marks this record as valid)
        branch.activeLength++;

        // Emit event
        emit RefUpdated(refKey, refName, parentOid, newOid, packfileSize, block.timestamp);
    }

    /**
     * @dev Force push (supports three scenarios)
     * 1. Delete Branch: newOid=0 → activeLength=0 + marks exists=false
     * 2. Full History Replacement: parentOid=0 → activeLength reset to 0, then add 1 new record
     * 3. Partial History Replacement: parentOid≠0 → activeLength truncated to parentIndex+1, then add 1 new record
     */
    function forcePush(
        bytes calldata refName,
        bytes20 newOid,
        bytes20 packfileKey,
        uint256 packfileSize,
        bytes20 parentOid,
        uint256 parentIndex
    ) external onlyMaintainer nonReentrant {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        PushRecord[] storage records = _branchRecords[refKey];
        require(branch.exists, "EthsHub: Branch does not exist");

        bytes20 oldOid = branch.headOid; // Record old head for event traceability

        // ====== Scenario 1: Delete Branch (newOid=0, Logical clear) ======
        if (newOid == bytes20(0)) {
            bytes32 defaultRefKey = _keccak256(defaultBranchName);
            require(refKey != defaultRefKey, "EthsHub: Cannot delete default branch");

            // 1. Remove branch name from _branchNames (avoid counting invalid branches)
            uint256 branchIdx = _branchNameIndex[refKey];
            require(branchIdx < _branchNames.length, "EthsHub: Branch not in name list");

            // Use the last branch to cover the current position (O(1) operation, saves gas)
            if (branchIdx < _branchNames.length - 1) {
                bytes memory lastBranchName = _branchNames[_branchNames.length - 1];
                bytes32 lastRefKey = _keccak256(lastBranchName);
                _branchNameIndex[lastRefKey] = branchIdx; // Update the index of the last branch
                _branchNames[branchIdx] = lastBranchName;
            }
            _branchNames.pop();
            delete _branchNameIndex[refKey]; // Clean up index mapping

            // 2. Logical clear: Only modify activeLength and exists, do not touch the physical array (Gas saving)
            branch.activeLength = 0;
            branch.headOid = bytes20(0);
            branch.exists = false;

            // Emit deletion event
            emit BranchDeleted(refName, block.timestamp);
            return;
        }

        // ====== Scenario 2: Full History Replacement (parentOid=0, new chain has no common ancestor) ======
        if (parentOid == bytes20(0)) {
            // 1. Logical clear of old records (activeLength reset to 0)
            branch.activeLength = 0;

            // 2. Add new record (index=0, overrides old data or adds new)
            PushRecord memory newRecord1 = PushRecord({
                newOid: newOid,
                parentOid: parentOid,
                packfileKey: packfileKey,
                size: packfileSize,
                timestamp: block.timestamp,
                pusher: msg.sender
            });
            _writeRecord(records, branch.activeLength, newRecord1);
            branch.activeLength++; // Active length becomes 1

            // 3. Update branch head
            branch.headOid = newOid;

            // Emit force update event
            emit ForceRefUpdated(refKey, refName, oldOid, newOid, block.timestamp);
            return;
        }

        // ====== Scenario 3: Partial History Replacement (parentOid≠0, truncate to parent record) ======
        // Boundary check 1: parentIndex must be within the logical active range
        require(parentIndex < branch.activeLength, "EthsHub: Parent index out of valid range");
        // Boundary check 2: parentOid must match the record at the index (ensure correct parent record)
        require(records[parentIndex].newOid == parentOid, "EthsHub: Parent OID not match");
        // NOTE: Changed from records[parentIndex].parentOid to .newOid as parentOid is usually the 'old' head

        // 1. Logical truncation: Active length set to parentIndex + 1 (subsequent records are considered invalid)
        branch.activeLength = parentIndex + 1;

        // 2. Add new record (index=current activeLength, overrides or adds new)
        PushRecord memory newRecord2 = PushRecord({
            newOid: newOid,
            parentOid: parentOid,
            packfileKey: packfileKey,
            size: packfileSize,
            timestamp: block.timestamp,
            pusher: msg.sender
        });
        _writeRecord(records, branch.activeLength, newRecord2);
        branch.activeLength++; // Active length + 1 (includes the new record)

        // 3. Update branch head
        branch.headOid = newOid;

        // Emit force update event
        emit ForceRefUpdated(refKey, refName, oldOid, newOid, block.timestamp);
    }

    // Set default branch
    function setDefaultBranch(bytes calldata branchName) external onlyMaintainer {
        bytes32 refKey = _keccak256(branchName);
        require(_branches[refKey].exists, "EthsHub: Branch not exists");

        bytes memory oldBranch = defaultBranchName;
        defaultBranchName = branchName;

        emit DefaultBranchChanged(oldBranch, branchName);
    }

    // ======================== Query ========================
    /**
     * @dev Paginates and retrieves the list of branches (only returns active branches).
     */
    function listBranches(uint256 start, uint256 limit) external view returns (RefData[] memory list) {
        uint256 end = start + limit;
        if (end > _branchNames.length) {
            end = _branchNames.length;
        }

        uint256 count = end > start ? end - start : 0;
        list = new RefData[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes memory branchName = _branchNames[start + i];
            bytes32 refKey = _keccak256(branchName);
            list[i] = RefData({name: branchName, hash: _branches[refKey].headOid});
        }
    }

    /**
     * @dev Gets the total count of active branches.
     */
    function getBranchCount() external view returns (uint256) {
        return _branchNames.length;
    }

    /**
     * @dev Gets the default branch information.
     */
    function getDefaultBranch() external view returns (bytes memory name, bytes20 headOid) {
        bytes32 refKey = _keccak256(defaultBranchName);
        return (defaultBranchName, _branches[refKey].headOid);
    }

    /**
     * @dev Gets the latest head information for a branch.
     */
    function getBranchHead(bytes calldata refName) external view returns (bytes20 headOid, bool exists) {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        return (branch.headOid, branch.exists);
    }

    /**
     * @dev Paginates and retrieves push records (only returns logically valid records).
     */
    function getPushRecords(bytes calldata refName, uint256 startIndex, uint256 count)
        external
        view
        returns (PushRecord[] memory)
    {
        bytes32 refKey = _keccak256(refName);
        Branch storage branch = _branches[refKey];
        PushRecord[] storage records = _branchRecords[refKey];
        require(branch.exists, "EthsHub: Branch not exists");

        // Boundary 1: If startIndex is out of the active range, return an empty array
        if (startIndex >= branch.activeLength) {
            return new PushRecord[](0);
        }
        // Boundary 2: endIndex must not exceed the logical active length
        uint256 endIndex = startIndex + count;
        if (endIndex > branch.activeLength) {
            endIndex = branch.activeLength;
        }

        // Assemble the valid records
        uint256 resultCount = endIndex - startIndex;
        PushRecord[] memory results = new PushRecord[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            results[i] = records[startIndex + i]; // Only retrieve records within the active range
        }
        return results;
    }

    // ---------------------- Database fallback ----------------------

    // Database interaction proxy (forward necessary calls only)
    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes4 selector;
        assembly {
            // Correctly load the 4-byte selector from the high-order bytes of calldata(0)
            // by right-shifting the 32-byte word by 224 bits.
            selector := shr(224, calldataload(0))
        }

        // Write check: Restrict access to DB write functions to authorized roles
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

    /**
     * @dev Safely writes a PushRecord to the array based on the current activeLength.
     * Performs an in-place overwrite if records.length > activeLength,
     * or calls push() if records.length == activeLength to expand the physical array.
     * @param records The physical PushRecord[] storage array.
     * @param activeLength The current logical length (the index where the new record should go).
     * @param newRecord The record data to write.
     */
    function _writeRecord(PushRecord[] storage records, uint256 activeLength, PushRecord memory newRecord) internal {
        // 1. Case: Physical array is large enough (records.length > activeLength)
        // This occurs after a forcePush has logically truncated the array. We safely overwrite the old, invalid data.
        if (records.length > activeLength) {
            records[activeLength] = newRecord;
        }
        // 2. Case: Physical array is exactly at the logical limit (records.length == activeLength)
        // This is the normal appending case. We must use push() to physically expand the array by one.
        else if (records.length == activeLength) {
            records.push(newRecord);
        }
        // 3. Case: Integrity check (records.length < activeLength)
        // This should never happen and indicates a storage corruption.
        else {
            revert("EthsHub: Storage corruption (Active length exceeds physical length)");
        }
    }
}
