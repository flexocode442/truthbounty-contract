// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../governance/GovernanceOwnable.sol";
import "../interfaces/ITruthBountyEvents.sol";
import "../governance/GovernanceHooks.sol";
import "../governance/GovernanceController.sol";
import "../IReputationOracle.sol";

interface ITruthBountyWeighted {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function GOVERNANCE_ROLE() external view returns (bytes32);
    function bountyToken() external view returns (address);
    function reputationOracle() external view returns (address);
    function verificationWindowDuration() external view returns (uint256);
    function minStakeAmount() external view returns (uint256);
    function settlementThresholdPercent() external view returns (uint256);
    function rewardPercent() external view returns (uint256);
    function slashPercent() external view returns (uint256);
}

interface IStaking {
    function stakingToken() external view returns (address);
}

interface IVerifierSlashing {
    function setStakingContract(address _staking) external;
    function grantRole(bytes32 role, address account) external;
}

interface IWeightedStaking {
    function reputationOracle() external view returns (address);
}

interface ITruthBountyClaims {
    function bountyToken() external view returns (address);
}

contract BootstrapController is ReentrancyGuard, Pausable, GovernanceOwnable, ITruthBountyEvents {
    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    // ============ Constants ============

    string public constant PROTOCOL_VERSION = "2.0.0";

    bytes32 public constant MODULE_GOVERNANCE = keccak256("GOVERNANCE");
    bytes32 public constant MODULE_TOKEN = keccak256("TOKEN");
    bytes32 public constant MODULE_REPUTATION_ORACLE = keccak256("REPUTATION_ORACLE");
    bytes32 public constant MODULE_TRUTH_BOUNTY = keccak256("TRUTH_BOUNTY");
    bytes32 public constant MODULE_STAKING = keccak256("STAKING");
    bytes32 public constant MODULE_VERIFIER_SLASHING = keccak256("VERIFIER_SLASHING");
    bytes32 public constant MODULE_WEIGHTED_STAKING = keccak256("WEIGHTED_STAKING");
    bytes32 public constant MODULE_CLAIMS = keccak256("CLAIMS");
    bytes32 public constant MODULE_REPUTATION_DECAY = keccak256("REPUTATION_DECAY");
    bytes32 public constant MODULE_REPUTATION_SNAPSHOT = keccak256("REPUTATION_SNAPSHOT");
    bytes32 public constant MODULE_REPUTATION_RECEIVER = keccak256("REPUTATION_RECEIVER");
    bytes32 public constant MODULE_INSURANCE = keccak256("INSURANCE");

    bytes32[] private _standardModuleOrder;

    // ============ Structs ============

    struct ModuleInfo {
        address addr;
        bool registered;
        bool initialized;
        string name;
    }

    struct BootstrapConfig {
        uint256 verificationWindowDuration;
        uint256 minStakeAmount;
        uint256 settlementThresholdPercent;
        uint256 rewardPercent;
        uint256 slashPercent;
        uint256 confirmationDelay;
        uint256 minReputationScore;
        uint256 maxReputationScore;
        uint256 defaultReputationScore;
        uint256 stakingLockDuration;
    }

    struct BootstrapState {
        bool bootstrapped;
        uint256 bootstrapTimestamp;
        uint256 blockNumber;
        string version;
        address bootstrapper;
    }

    // ============ State Variables ============

    mapping(bytes32 => ModuleInfo) public modules;
    mapping(uint256 => bytes32) private _moduleIndex;
    uint256 public moduleCount;

    BootstrapState public bootstrapState;
    BootstrapConfig public config;

    // ============ Events ============

    event ProtocolBootstrapStarted();

    event ModuleRegistered(
        bytes32 indexed moduleId,
        address indexed module,
        string name
    );

    event ModuleInitialized(
        bytes32 indexed moduleId,
        address indexed module
    );

    event ProtocolBootstrapCompleted(
        string version
    );

    event BootstrapValidationFailed(
        bytes32 indexed reason
    );

    event BootstrapConfigUpdated(
        bytes32 indexed paramId,
        uint256 oldValue,
        uint256 newValue
    );

    // ============ Errors ============

    error AlreadyBootstrapped();
    error NotBootstrapped();
    error ModuleAlreadyRegistered(bytes32 moduleId);
    error ModuleNotRegistered(bytes32 moduleId);
    error ModuleNotInitialized(bytes32 moduleId);
    error InvalidAddress();
    error MissingDependency(bytes32 dependency);
    error ConfigurationMismatch(bytes32 paramId);
    error EmptyModuleName();

    // ============ Constructor ============

    constructor(
        address initialAdmin,
        address _governanceController
    ) {
        require(initialAdmin != address(0), "Invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(DEPLOYER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);

        _setRoleAdmin(DEPLOYER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);

        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);

        _buildStandardModuleOrder();
    }

    // ============ Module Registration ============

    function registerModule(
        bytes32 moduleId,
        address moduleAddress,
        string calldata name
    ) external onlyRole(DEPLOYER_ROLE) nonReentrant {
        if (moduleAddress == address(0)) revert InvalidAddress();
        if (modules[moduleId].registered) revert ModuleAlreadyRegistered(moduleId);
        if (bytes(name).length == 0) revert EmptyModuleName();

        modules[moduleId] = ModuleInfo({
            addr: moduleAddress,
            registered: true,
            initialized: false,
            name: name
        });

        _moduleIndex[moduleCount] = moduleId;
        moduleCount++;

        emit ModuleRegistered(moduleId, moduleAddress, name);
    }

    function registerModules(
        bytes32[] calldata moduleIds_,
        address[] calldata addresses,
        string[] calldata names
    ) external onlyRole(DEPLOYER_ROLE) nonReentrant {
        uint256 len = moduleIds_.length;
        require(len == addresses.length && len == names.length, "Array length mismatch");

        for (uint256 i = 0; i < len; i++) {
            if (addresses[i] == address(0)) revert InvalidAddress();
            if (modules[moduleIds_[i]].registered) revert ModuleAlreadyRegistered(moduleIds_[i]);
            if (bytes(names[i]).length == 0) revert EmptyModuleName();

            modules[moduleIds_[i]] = ModuleInfo({
                addr: addresses[i],
                registered: true,
                initialized: false,
                name: names[i]
            });

            _moduleIndex[moduleCount] = moduleIds_[i];
            moduleCount++;

            emit ModuleRegistered(moduleIds_[i], addresses[i], names[i]);
        }
    }

    // ============ Configuration ============

    function setBootstrapConfig(BootstrapConfig calldata _config) external onlyRole(DEPLOYER_ROLE) {
        config = _config;
    }

    // ============ Bootstrap Execution ============

    function bootstrap() external nonReentrant onlyRole(DEPLOYER_ROLE) {
        if (bootstrapState.bootstrapped) revert AlreadyBootstrapped();

        emit ProtocolBootstrapStarted();

        _validateAllModulesRegistered();
        _validateDependencies();
        _validateConfiguration();

        _initializeModules();

        bootstrapState.bootstrapped = true;
        bootstrapState.bootstrapTimestamp = block.timestamp;
        bootstrapState.blockNumber = block.number;
        bootstrapState.version = PROTOCOL_VERSION;
        bootstrapState.bootstrapper = msg.sender;

        emit ProtocolBootstrapCompleted(PROTOCOL_VERSION);
    }

    // ============ Internal: Validation ============

    function _validateAllModulesRegistered() internal view {
        for (uint256 i = 0; i < _standardModuleOrder.length; i++) {
            bytes32 modId = _standardModuleOrder[i];
            if (!modules[modId].registered) {
                revert ModuleNotRegistered(modId);
            }
        }
    }

    function _validateDependencies() internal view {
        _requireModule(MODULE_GOVERNANCE);
        _requireModule(MODULE_TOKEN);
        _requireModule(MODULE_REPUTATION_ORACLE);
        _requireModule(MODULE_TRUTH_BOUNTY);
        _requireModule(MODULE_STAKING);
        _requireModule(MODULE_VERIFIER_SLASHING);
        _requireModule(MODULE_WEIGHTED_STAKING);
        _requireModule(MODULE_CLAIMS);

        address govAddr = modules[MODULE_GOVERNANCE].addr;
        address tokenAddr = modules[MODULE_TOKEN].addr;
        address oracleAddr = modules[MODULE_REPUTATION_ORACLE].addr;
        address bountyAddr = modules[MODULE_TRUTH_BOUNTY].addr;
        address stakingAddr = modules[MODULE_STAKING].addr;

        try ITruthBountyWeighted(bountyAddr).bountyToken() returns (address bt) {
            if (bt != tokenAddr) revert ConfigurationMismatch(keccak256("BOUNTY_TOKEN"));
        } catch {
            revert ConfigurationMismatch(keccak256("TRUTH_BOUNTY_INTERFACE"));
        }

        try ITruthBountyWeighted(bountyAddr).reputationOracle() returns (address ro) {
            if (ro != oracleAddr) revert ConfigurationMismatch(keccak256("REPUTATION_ORACLE"));
        } catch {
            revert ConfigurationMismatch(keccak256("TRUTH_BOUNTY_INTERFACE"));
        }

        try IWeightedStaking(modules[MODULE_WEIGHTED_STAKING].addr).reputationOracle() returns (address wro) {
            if (wro != oracleAddr) revert ConfigurationMismatch(keccak256("WEIGHTED_STAKING_ORACLE"));
        } catch {
            revert ConfigurationMismatch(keccak256("WEIGHTED_STAKING_INTERFACE"));
        }

        try IStaking(stakingAddr).stakingToken() returns (address st) {
            if (st != tokenAddr) revert ConfigurationMismatch(keccak256("STAKING_TOKEN"));
        } catch {
            revert ConfigurationMismatch(keccak256("STAKING_INTERFACE"));
        }

        try ITruthBountyClaims(modules[MODULE_CLAIMS].addr).bountyToken() returns (address ct) {
            if (ct != tokenAddr) revert ConfigurationMismatch(keccak256("CLAIMS_TOKEN"));
        } catch {
            revert ConfigurationMismatch(keccak256("CLAIMS_INTERFACE"));
        }

        address controllerAddr = modules[MODULE_GOVERNANCE].addr;

        if (!ITruthBountyWeighted(bountyAddr).hasRole(ITruthBountyWeighted(bountyAddr).GOVERNANCE_ROLE(), controllerAddr)) {
            if (!ITruthBountyWeighted(bountyAddr).hasRole(0x00, controllerAddr)) {
                revert ConfigurationMismatch(keccak256("GOVERNANCE_ROLES"));
            }
        }
    }

    function _validateConfiguration() internal {
        BootstrapConfig memory cfg = config;

        if (cfg.verificationWindowDuration < 1 days || cfg.verificationWindowDuration > 30 days) {
            emit BootstrapValidationFailed(keccak256("INVALID_VERIFICATION_WINDOW"));
        }
        if (cfg.minStakeAmount == 0) {
            emit BootstrapValidationFailed(keccak256("INVALID_MIN_STAKE"));
        }
        if (cfg.settlementThresholdPercent == 0 || cfg.settlementThresholdPercent > 100) {
            emit BootstrapValidationFailed(keccak256("INVALID_THRESHOLD"));
        }
        if (cfg.rewardPercent == 0 || cfg.rewardPercent > 100) {
            emit BootstrapValidationFailed(keccak256("INVALID_REWARD_PERCENT"));
        }
        if (cfg.slashPercent == 0 || cfg.slashPercent > 100) {
            emit BootstrapValidationFailed(keccak256("INVALID_SLASH_PERCENT"));
        }
        if (cfg.minReputationScore == 0 || cfg.minReputationScore >= cfg.maxReputationScore) {
            emit BootstrapValidationFailed(keccak256("INVALID_REPUTATION_BOUNDS"));
        }
        if (cfg.defaultReputationScore == 0) {
            emit BootstrapValidationFailed(keccak256("INVALID_DEFAULT_REPUTATION"));
        }
        if (cfg.stakingLockDuration < 1 hours) {
            emit BootstrapValidationFailed(keccak256("INVALID_STAKING_DURATION"));
        }
    }

    function _requireModule(bytes32 moduleId) internal view {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
    }

    // ============ Internal: Initialization ============

    function _initializeModules() internal {
        _initModule(MODULE_GOVERNANCE);
        _initModule(MODULE_TOKEN);
        _initModule(MODULE_REPUTATION_ORACLE);
        _initModule(MODULE_STAKING);
        _initModule(MODULE_REPUTATION_DECAY);
        _initModule(MODULE_REPUTATION_SNAPSHOT);
        _initModule(MODULE_WEIGHTED_STAKING);
        _initModule(MODULE_TRUTH_BOUNTY);

        _wireVerifierSlashing();

        _initModule(MODULE_VERIFIER_SLASHING);
        _initModule(MODULE_CLAIMS);
        _initModule(MODULE_REPUTATION_RECEIVER);
        _initModule(MODULE_INSURANCE);
    }

    function _initModule(bytes32 moduleId) internal {
        ModuleInfo storage mod = modules[moduleId];
        if (mod.registered && !mod.initialized) {
            mod.initialized = true;
            emit ModuleInitialized(moduleId, mod.addr);
        }
    }

    function _wireVerifierSlashing() internal {
        address slashingAddr = modules[MODULE_VERIFIER_SLASHING].addr;
        address stakingAddr = modules[MODULE_STAKING].addr;

        if (slashingAddr != address(0)) {
            try IVerifierSlashing(slashingAddr).setStakingContract(stakingAddr) {
                emit ModuleInitialized(keccak256("VERIFIER_SLASHING_WIRING"), slashingAddr);
            } catch {
                emit BootstrapValidationFailed(keccak256("VERIFIER_SLASHING_WIRING_FAILED"));
            }
        }
    }

    // ============ Internal: Module Order ============

    function _buildStandardModuleOrder() internal {
        delete _standardModuleOrder;
        _standardModuleOrder.push(MODULE_GOVERNANCE);
        _standardModuleOrder.push(MODULE_TOKEN);
        _standardModuleOrder.push(MODULE_REPUTATION_ORACLE);
        _standardModuleOrder.push(MODULE_STAKING);
        _standardModuleOrder.push(MODULE_REPUTATION_DECAY);
        _standardModuleOrder.push(MODULE_REPUTATION_SNAPSHOT);
        _standardModuleOrder.push(MODULE_WEIGHTED_STAKING);
        _standardModuleOrder.push(MODULE_TRUTH_BOUNTY);
        _standardModuleOrder.push(MODULE_VERIFIER_SLASHING);
        _standardModuleOrder.push(MODULE_CLAIMS);
        _standardModuleOrder.push(MODULE_REPUTATION_RECEIVER);
        _standardModuleOrder.push(MODULE_INSURANCE);
    }

    // ============ View Functions ============

    function isBootstrapped() external view returns (bool) {
        return bootstrapState.bootstrapped;
    }

    function getModuleAddress(bytes32 moduleId) external view returns (address) {
        if (!modules[moduleId].registered) revert ModuleNotRegistered(moduleId);
        return modules[moduleId].addr;
    }

    function isModuleInitialized(bytes32 moduleId) external view returns (bool) {
        return modules[moduleId].initialized;
    }

    function getModuleInfo(bytes32 moduleId) external view returns (ModuleInfo memory) {
        return modules[moduleId];
    }

    function getModuleCount() external view returns (uint256) {
        return moduleCount;
    }

    function getModuleAt(uint256 index) external view returns (bytes32 moduleId, ModuleInfo memory info) {
        require(index < moduleCount, "Index out of bounds");
        moduleId = _moduleIndex[index];
        info = modules[moduleId];
    }

    function getAllModules() external view returns (bytes32[] memory ids, ModuleInfo[] memory infos) {
        ids = new bytes32[](moduleCount);
        infos = new ModuleInfo[](moduleCount);
        for (uint256 i = 0; i < moduleCount; i++) {
            ids[i] = _moduleIndex[i];
            infos[i] = modules[ids[i]];
        }
    }

    function getStandardModuleOrder() external view returns (bytes32[] memory) {
        return _standardModuleOrder;
    }

    function getBootstrapState() external view returns (BootstrapState memory) {
        return bootstrapState;
    }

    function getBootstrapConfig() external view returns (BootstrapConfig memory) {
        return config;
    }

    function isFullyInitialized() external view returns (bool) {
        if (!bootstrapState.bootstrapped) return false;
        for (uint256 i = 0; i < _standardModuleOrder.length; i++) {
            bytes32 modId = _standardModuleOrder[i];
            if (modules[modId].registered && !modules[modId].initialized) {
                return false;
            }
        }
        return true;
    }

    // ============ Pause ============

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPauseActivatedV1(

            msg.sender,

            keccak256("MANUAL_PAUSE"),

            uint64(block.timestamp),

            EVENT_SCHEMA_VERSION

        );
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
        emit EmergencyPauseRecoveredV1(

            msg.sender,

            uint64(block.timestamp),

            EVENT_SCHEMA_VERSION

        );
    }
}
