// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./GovernanceHooks.sol";
import "./GovernorAccess.sol";
import "../interfaces/ITruthBountyEvents.sol";

/**
 * @title GovernanceController
 * @notice Central governance controller for TruthBounty protocol
 * @dev Handles parameter updates, role assignments, and upgrade authorizations
 * 
 * Flow:
 * 1. Anyone can request a parameter update via governance proposal
 * 2. DAO votes on the proposal (handled by external governance system)
 * 3. Once approved, proposal can be executed here
 * 4. Execution updates the target contract parameters
 */
contract GovernanceController is GovernorAccessControl, ReentrancyGuard, GovernanceHooks, ITruthBountyEvents {
    // ============ Constants ============
    
    uint256 public constant MIN_PROPOSAL_DELAY = 1 hours;
    uint256 public constant MAX_PROPOSAL_DELAY = 30 days;
    uint16 public constant EVENT_SCHEMA_VERSION = 1;
    
    // ============ State Variables ============
    
    /// @notice Parameter values storage (for parameters that need to be tracked here)
    mapping(ParameterType => uint256) public parameterValues;
    mapping(ParameterType => address) public parameterAddresses;
    
    /// @notice Pending proposals
    mapping(bytes32 => Proposal) public proposals;
    
    /// @notice Set of pending proposal IDs for enumeration
    bytes32[] public pendingProposalIds;
    mapping(bytes32 => bool) public isProposalPendingSet;
    
    /// @notice Timelock for execution
    uint256 public proposalTimelock = MIN_PROPOSAL_DELAY;
    
    /// @notice Contract version for tracking
    uint256 public version = 1;

    // ============ Data Structures ============
    
    struct Proposal {
        bytes32 id;
        ParameterType paramType;
        uint256 oldValue;
        uint256 newValue;
        address newAddress;
        uint8 status; // 0=Pending, 1=Executed, 2=Cancelled
        address proposer;
        uint256 createdAt;
        uint256 executeAfter;
    }

    // ============ Custom Errors ============
    
    error InvalidParameterType(uint256 paramType);
    error ProposalNotPending(bytes32 proposalId);
    error ProposalAlreadyExecuted(bytes32 proposalId);
    error ProposalAlreadyCancelled(bytes32 proposalId);
    error TimelockNotPassed(uint256 executeAfter);
    error NoValueChange();
    error ZeroAddress();

    // ============ Modifiers ============
    
    modifier onlyProposalExecutor() override {
        if (!hasRole(GovernorAccess.PROPOSAL_EXECUTOR_ROLE, msg.sender) && 
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GovernorAccess.PROPOSAL_EXECUTOR_ROLE);
        }
        _;
    }

    // ============ Events ============
    
    event ProposalTimelockUpdated(uint256 oldTimelock, uint256 newTimelock);
    event ContractVersionUpdated(uint256 oldVersion, uint256 newVersion);

    // ============ Constructor ============
    
    /**
     * @notice Initialize governance controller
     * @param initialAdmin The initial admin address
     */
    constructor(address initialAdmin) {
        require(initialAdmin != address(0), ZeroAddress());
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(GovernorAccess.GOVERNANCE_ROLE, initialAdmin);
        _grantRole(GovernorAccess.PROPOSAL_EXECUTOR_ROLE, initialAdmin);
        _grantRole(GovernorAccess.PARAMETER_MANAGER_ROLE, initialAdmin);
    }

    // ============ Parameter Update Functions ============

    /**
     * @notice Request a parameter update
     * @param paramType The parameter type to update
     * @param newValue The new value
     * @return proposalId The created proposal ID
     */
    function requestParameterUpdate(
        ParameterType paramType,
        uint256 newValue
    ) external nonReentrant returns (bytes32 proposalId) {
        uint256 paramTypeUint = uint256(paramType);
        if (paramTypeUint > 50) revert InvalidParameterType(paramTypeUint);
        
        uint256 oldValue = getParameterValue(paramType);
        if (oldValue == newValue) revert NoValueChange();
        
        proposalId = _createProposal(
            paramType,
            oldValue,
            newValue,
            address(0)
        );
        
        emit ParameterUpdateRequested(
            paramType,
            proposalId,
            oldValue,
            newValue,
            msg.sender
        );
    }

    /**
     * @notice Request an address parameter update
     * @param paramType The parameter type to update
     * @param newAddress The new address
     * @return proposalId The created proposal ID
     */
    function requestAddressParameterUpdate(
        ParameterType paramType,
        address newAddress
    ) external nonReentrant returns (bytes32 proposalId) {
        uint256 paramTypeUint = uint256(paramType);
        if (paramTypeUint > 50) revert InvalidParameterType(paramTypeUint);
        
        if (newAddress == address(0)) revert ZeroAddress();
        
        address oldAddress = getParameterAddress(paramType);
        if (oldAddress == newAddress) revert NoValueChange();
        
        proposalId = _createProposal(
            paramType,
            0,
            0,
            newAddress
        );
        
        emit ParameterUpdateRequested(
            paramType,
            proposalId,
            0,
            0,
            msg.sender
        );
    }

    /**
     * @notice Execute an approved parameter update
     * @param proposalId The proposal ID to execute
     */
    function executeParameterUpdate(bytes32 proposalId) external nonReentrant onlyProposalExecutor {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotPending(proposalId);
        if (proposal.status != 0) {
            if (proposal.status == 1) revert ProposalAlreadyExecuted(proposalId);
            else revert ProposalAlreadyCancelled(proposalId);
        }
        
        if (block.timestamp < proposal.executeAfter) {
            revert TimelockNotPassed(proposal.executeAfter);
        }
        
        uint256 oldValue = proposal.paramType == ParameterType.REPUTATION_ORACLE ||
                         proposal.paramType == ParameterType.STAKING_CONTRACT
            ? uint256(uint160(proposals[proposalId].newAddress))
            : proposal.oldValue;
            
        // Update stored value
        if (proposal.newAddress != address(0)) {
            parameterAddresses[proposal.paramType] = proposal.newAddress;
        } else {
            parameterValues[proposal.paramType] = proposal.newValue;
        }
        
        proposal.status = 1;
        
        emit ParameterUpdateExecuted(
            proposal.paramType,
            proposalId,
            oldValue,
            proposal.newValue
        );
        emit GovernanceProposalExecutedV1(
            proposalId,
            msg.sender,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    /**
     * @notice Cancel a pending parameter update
     * @param proposalId The proposal ID to cancel
     */
    function cancelParameterUpdate(bytes32 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotPending(proposalId);
        if (proposal.status != 0) {
            if (proposal.status == 1) revert ProposalAlreadyExecuted(proposalId);
            else revert ProposalAlreadyCancelled(proposalId);
        }
        
        // Only proposer or admin can cancel
        if (proposal.proposer != msg.sender && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert("Not authorized");
        }
        
        proposal.status = 2;
        
        emit ParameterUpdateCancelled(proposal.paramType, proposalId);
    }

    // ============ Role Management Functions ============

    /**
     * @notice Request a role assignment
     * @param account The account to grant/revoke
     * @param role The role identifier
     * @param grant True to grant, false to revoke
     * @return proposalId The created proposal ID
     */
    function requestRoleAssignment(
        address account,
        bytes32 role,
        bool grant
    ) external nonReentrant returns (bytes32 proposalId) {
        if (account == address(0)) revert ZeroAddress();
        
        // Use special parameter type for role management
        ParameterType paramType = grant 
            ? ParameterType.RESOLVER_ROLE 
            : ParameterType.TREASURY_ROLE;
        
        proposalId = _createProposal(
            paramType,
            0,
            grant ? 1 : 0,
            account
        );
        
        emit RoleAssignmentRequested(
            proposalId,
            account,
            role,
            grant,
            msg.sender
        );
    }

    // ============ Upgrade Authorization Functions ============

    /**
     * @notice Request upgrade authorization
     * @param newImplementation The new implementation address
     * @return proposalId The created proposal ID
     */
    function requestUpgradeAuthorization(
        address newImplementation
    ) external nonReentrant returns (bytes32 proposalId) {
        if (newImplementation == address(0)) revert ZeroAddress();
        
        proposalId = _createProposal(
            ParameterType.UPGRADE_AUTHORIZATION,
            version,
            version + 1,
            newImplementation
        );
        
        emit UpgradeAuthorized(
            proposalId,
            newImplementation,
            msg.sender
        );
    }

    /**
     * @notice Execute an approved upgrade
     * @param proposalId The proposal ID to execute
     */
    function executeUpgrade(bytes32 proposalId) external onlyProposalExecutor {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotPending(proposalId);
        if (proposal.status != 0) {
            if (proposal.status == 1) revert ProposalAlreadyExecuted(proposalId);
            else revert ProposalAlreadyCancelled(proposalId);
        }
        
        if (block.timestamp < proposal.executeAfter) {
            revert TimelockNotPassed(proposal.executeAfter);
        }
        
        // Mark as executed
        proposal.status = 1;
        
        // Version bump
        uint256 oldVersion = version;
        version = proposal.newValue;
        
        emit ContractVersionUpdated(oldVersion, version);
        
        emit UpgradeExecuted(
            proposalId,
            proposal.newAddress
        );
        emit GovernanceProposalExecutedV1(
            proposalId,
            msg.sender,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    // ============ View Functions ============

    /**
     * @notice Get parameter value
     * @param paramType The parameter type
     * @return The current value
     */
    function getParameterValue(ParameterType paramType) public view returns (uint256) {
        return parameterValues[paramType];
    }

    /**
     * @notice Get parameter address
     * @param paramType The parameter type
     * @return The current address
     */
    function getParameterAddress(ParameterType paramType) public view returns (address) {
        return parameterAddresses[paramType];
    }

    /**
     * @notice Check if proposal is pending
     * @param proposalId The proposal ID
     * @return True if pending
     */
    function isProposalPending(bytes32 proposalId) external view returns (bool) {
        return proposals[proposalId].status == 0;
    }

    /**
     * @notice Get proposal details
     * @param proposalId The proposal ID to query
     * @return paramType The proposal parameter type
     * @return oldValue The old value before the proposal
     * @return newValue The proposed new value
     * @return newAddress The proposed new address value
     * @return status The proposal status code
     * @return proposer The account that created the proposal
     */
    function getProposalDetails(bytes32 proposalId) external view returns (
        ParameterType paramType,
        uint256 oldValue,
        uint256 newValue,
        address newAddress,
        uint8 status,
        address proposer
    ) {
        Proposal storage p = proposals[proposalId];
        return (
            p.paramType,
            p.oldValue,
            p.newValue,
            p.newAddress,
            p.status,
            p.proposer
        );
    }

    /**
     * @notice Get pending proposal count
     * @return The number of pending proposals
     */
    function getPendingProposalCount() external view returns (uint256) {
        return pendingProposalIds.length;
    }

    // ============ Internal Functions ============

    function _createProposal(
        ParameterType paramType,
        uint256 oldValue,
        uint256 newValue,
        address newAddress
    ) internal returns (bytes32 proposalId) {
        proposalId = keccak256(abi.encode(
            paramType,
            oldValue,
            newValue,
            newAddress,
            msg.sender,
            block.timestamp
        ));
        
        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.paramType = paramType;
        proposal.oldValue = oldValue;
        proposal.newValue = newValue;
        proposal.newAddress = newAddress;
        proposal.status = 0;
        proposal.proposer = msg.sender;
        proposal.createdAt = block.timestamp;
        proposal.executeAfter = block.timestamp + proposalTimelock;
        
        // Add to pending list
        if (!isProposalPendingSet[proposalId]) {
            pendingProposalIds.push(proposalId);
            isProposalPendingSet[proposalId] = true;
        }
        
        emit GovernanceProposalCreatedV1(
            proposalId,
            msg.sender,
            keccak256(abi.encode(paramType, oldValue, newValue, newAddress)),
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the proposal timelock
     * @param newTimelock The new timelock period
     */
    function setProposalTimelock(uint256 newTimelock) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTimelock >= MIN_PROPOSAL_DELAY, "Timelock too short");
        require(newTimelock <= MAX_PROPOSAL_DELAY, "Timelock too long");
        
        uint256 oldTimelock = proposalTimelock;
        proposalTimelock = newTimelock;
        
        emit ProposalTimelockUpdated(oldTimelock, newTimelock);
    }
}
