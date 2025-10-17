// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EthsHub} from "./EthsHub.sol";
import {IFlatDirectoryFactory} from "./interfaces/IFlatDirectoryFactory.sol";

contract EthsFactory is Ownable, ReentrancyGuard {
    event HubCreated(address indexed hub, address indexed creator, bytes repoName);
    event ImplementationUpdated(address indexed oldImp, address indexed newImp);
    event DbFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    
    address public dbFactory;
    address public hubImplementation;

    struct HubInfo {
        address hubAddress;
        uint256 creationTime;
        bytes repoName;
    }
    
    mapping(address => HubInfo[]) public hubsOf; //  creator => hubs

    constructor(address _dbFactory) Ownable(msg.sender) {
        require(_dbFactory != address(0), "EthsFactory: invalid db factory");
        dbFactory = _dbFactory;
        hubImplementation = address(new EthsHub());
    }

    function setHubImplementation(address _newImp) external onlyOwner {
        require(_newImp != address(0), "EthsFactory: invalid implementation");
        emit ImplementationUpdated(hubImplementation, _newImp);
        hubImplementation = _newImp;
    }
    
    function setDbFactory(address _newFactory) external onlyOwner {
        require(_newFactory != address(0), "EthsFactory: invalid db factory");
        emit DbFactoryUpdated(dbFactory, _newFactory);
        dbFactory = _newFactory;
    }
    
    function createHub(bytes memory repoName) external nonReentrant returns (address) {
        address hubInstance = Clones.clone(hubImplementation);
        EthsHub(payable(hubInstance)).initialize(
            msg.sender,
            repoName,
            IFlatDirectoryFactory(dbFactory)
        );
        
        HubInfo memory info = HubInfo({
            hubAddress: hubInstance,
            creationTime: block.timestamp,
            repoName: repoName
        });
        hubsOf[msg.sender].push(info);

        emit HubCreated(hubInstance, msg.sender, repoName);
        
        return hubInstance;
    }

    // ---------------------- query ----------------------
    function getUserHubCount(address user) external view returns (uint256) {
        return hubsOf[user].length;
    }
    
    function getUserHubsPaginated(address user, uint256 start, uint256 limit) external view returns (HubInfo[] memory) {
        HubInfo[] storage userHubs = hubsOf[user];

        uint256 end = start + limit;
        if (end > userHubs.length) end = userHubs.length;
        uint256 count = end > start ? end - start : 0;
        
        HubInfo[] memory result = new HubInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = userHubs[start + i];
        }
        return result;
    }
}
