// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../governance/GovernanceOwnable.sol";
import "../interfaces/ITruthBountyEvents.sol";

contract MigrationManager is ReentrancyGuard, Pausable, GovernanceOwnable, ITruthBountyEvents {
    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct Release {
        string version;
        uint256 timestamp;
        bytes32 gitCommit;
        address deployedBy;
        bool finalized;
        mapping(bytes32 => address) modules;
        bytes32[] moduleKeys;
    }

    struct Migration {
        uint256 id;
        string description;
        uint256 timestamp;
        address executor;
        bool executed;
        bytes32 migrationHash;
    }

    uint256 public migrationCounter;
    string public currentVersion;
    bytes32 public currentGitCommit;
    uint256 public deployTimestamp;
    address public deployOperator;

    mapping(bytes32 => address) public addressRegistry;
    mapping(bytes32 => bool) public registeredModules;
    bytes32[] public registeredModuleKeys;

    mapping(uint256 => Migration) public migrations;
    uint256[] public migrationIds;

    bool public ownershipVerified;
    bool public deploymentVerified;

    event ReleaseCreated(
        string indexed version,
        bytes32 indexed gitCommit,
        address indexed deployedBy
    );

    event ReleaseFinalized(string indexed version);

    event ModuleRegisteredInRegistry(
        bytes32 indexed moduleId,
        address indexed moduleAddress
    );

    event MigrationExecuted(
        uint256 indexed migrationId,
        string description,
        address indexed executor
    );

    event AddressUpdated(
        bytes32 indexed moduleId,
        address indexed oldAddress,
        address indexed newAddress
    );

    event DeploymentVerified(bool ownershipTransferred, bool allModulesInitialized);

    event OwnershipTransferred(
        bytes32 indexed moduleId,
        address indexed oldOwner,
        address indexed newOwner
    );

    error ReleaseAlreadyFinalized();
    error ReleaseNotFinalized();
    error ModuleAlreadyRegistered(bytes32 moduleId);
    error ModuleNotRegistered(bytes32 moduleId);
    error MigrationAlreadyExecuted(uint256 migrationId);
    error InvalidVersion();
    error InvalidAddress();
    error DeploymentNotVerified();

    constructor(
        address initialAdmin,
        address _governanceController
    ) {
        require(initialAdmin != address(0), "Invalid admin");
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(MIGRATOR_ROLE, initialAdmin);
        _grantRole(UPGRADER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _setRoleAdmin(MIGRATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);
    }

    function createRelease(
        string calldata version,
        bytes32 gitCommit
    ) external onlyRole(MIGRATOR_ROLE) nonReentrant {
        if (bytes(version).length == 0) revert InvalidVersion();
        currentVersion = version;
        currentGitCommit = gitCommit;
        deployTimestamp = block.timestamp;
        deployOperator = msg.sender;
        emit ReleaseCreated(version, gitCommit, msg.sender);
    }

    function registerModuleInRegistry(
        bytes32 moduleId,
        address moduleAddress
    ) external onlyRole(MIGRATOR_ROLE) {
        if (moduleAddress == address(0)) revert InvalidAddress();
        if (registeredModules[moduleId]) revert ModuleAlreadyRegistered(moduleId);
        addressRegistry[moduleId] = moduleAddress;
        registeredModules[moduleId] = true;
        registeredModuleKeys.push(moduleId);
        emit ModuleRegisteredInRegistry(moduleId, moduleAddress);
    }

    function updateModuleAddress(
        bytes32 moduleId,
        address newAddress
    ) external onlyRole(MIGRATOR_ROLE) {
        if (newAddress == address(0)) revert InvalidAddress();
        if (!registeredModules[moduleId]) revert ModuleNotRegistered(moduleId);
        address oldAddress = addressRegistry[moduleId];
        addressRegistry[moduleId] = newAddress;
        emit AddressUpdated(moduleId, oldAddress, newAddress);
    }

    function executeMigration(
        string calldata description,
        bytes32 migrationHash
    ) external onlyRole(MIGRATOR_ROLE) nonReentrant {
        uint256 id = migrationCounter++;
        migrations[id] = Migration({
            id: id,
            description: description,
            timestamp: block.timestamp,
            executor: msg.sender,
            executed: true,
            migrationHash: migrationHash
        });
        migrationIds.push(id);
        emit MigrationExecuted(id, description, msg.sender);
    }

    function verifyDeployment(
        bool _ownershipTransferred,
        bool _allModulesInitialized
    ) external onlyRole(MIGRATOR_ROLE) {
        ownershipVerified = _ownershipTransferred;
        deploymentVerified = _allModulesInitialized;
        emit DeploymentVerified(_ownershipTransferred, _allModulesInitialized);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); emit EmergencyPauseActivatedV1(
     msg.sender,
     keccak256("MANUAL_PAUSE"),
     uint64(block.timestamp),
     EVENT_SCHEMA_VERSION
 ); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); emit EmergencyPauseRecoveredV1(
     msg.sender,
     uint64(block.timestamp),
     EVENT_SCHEMA_VERSION
 ); }

    function getModuleAddress(bytes32 moduleId) external view returns (address) {
        if (!registeredModules[moduleId]) revert ModuleNotRegistered(moduleId);
        return addressRegistry[moduleId];
    }

    function getRegisteredModuleCount() external view returns (uint256) {
        return registeredModuleKeys.length;
    }

    function getRegisteredModuleAt(uint256 index) external view returns (bytes32 moduleId, address moduleAddress) {
        require(index < registeredModuleKeys.length, "Index out of bounds");
        moduleId = registeredModuleKeys[index];
        moduleAddress = addressRegistry[moduleId];
    }

    function getAllRegisteredModules() external view returns (bytes32[] memory ids, address[] memory addresses) {
        ids = registeredModuleKeys;
        addresses = new address[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            addresses[i] = addressRegistry[ids[i]];
        }
    }

    function getMigrationCount() external view returns (uint256) {
        return migrationIds.length;
    }

    function getMigrationAt(uint256 index) external view returns (Migration memory) {
        require(index < migrationIds.length, "Index out of bounds");
        return migrations[migrationIds[index]];
    }

    function getAllMigrations() external view returns (Migration[] memory) {
        Migration[] memory result = new Migration[](migrationIds.length);
        for (uint256 i = 0; i < migrationIds.length; i++) {
            result[i] = migrations[migrationIds[i]];
        }
        return result;
    }

    function isModuleRegistered(bytes32 moduleId) external view returns (bool) {
        return registeredModules[moduleId];
    }
}
