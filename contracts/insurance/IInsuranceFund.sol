// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IInsuranceFund
 * @notice Interface for the Protocol Insurance Fund & Loss Recovery Framework
 * @dev Defines the public API for funding, claims, payouts, and reserve queries
 */
interface IInsuranceFund {
    // ============ Enums ============

    enum CoverageCategory {
        SMART_CONTRACT_FAILURE,
        ECONOMIC_ATTACK,
        ORACLE_FAILURE,
        GOVERNANCE_INCIDENT
    }

    enum ClaimState {
        SUBMITTED,
        INVESTIGATING,
        REVIEW,
        APPROVED,
        REJECTED,
        PAID
    }

    enum FundingSource {
        PROTOCOL_FEE,
        SLASHED_STAKE,
        GOVERNANCE,
        TREASURY_TRANSFER,
        EXTERNAL_DONATION
    }

    // ============ Structs ============

    struct Claim {
        uint256 id;
        address claimant;
        CoverageCategory category;
        uint256 requestedAmount;
        uint256 approvedAmount;
        ClaimState state;
        string descriptionURI;
        string auditRecordURI;
        uint256 submittedAt;
        uint256 resolvedAt;
    }

    struct FundingRecord {
        FundingSource source;
        uint256 amount;
        address funder;
        uint256 timestamp;
    }

    struct ReserveMetrics {
        uint256 currentBalance;
        uint256 totalFunded;
        uint256 totalPaidOut;
        uint256 activeClaims;
        uint256 utilisationBasisPoints;
        uint256 growthRateLast30Days;
    }

    // ============ Events ============

    event InsuranceFunded(
        address indexed funder,
        FundingSource indexed source,
        uint256 amount
    );

    event InsuranceClaimSubmitted(
        uint256 indexed claimId,
        address indexed claimant,
        CoverageCategory indexed category,
        uint256 requestedAmount
    );

    event InsuranceClaimStateUpdated(
        uint256 indexed claimId,
        ClaimState oldState,
        ClaimState newState,
        address indexed updatedBy
    );

    event InsuranceClaimApproved(
        bytes32 indexed claimId,
        uint256 amount
    );

    event InsuranceClaimRejected(
        uint256 indexed claimId,
        string indexed reason,
        address indexed rejectedBy
    );

    event InsurancePayoutExecuted(
        address indexed recipient,
        uint256 amount,
        uint256 indexed claimId
    );

    event InsurancePolicyUpdated(
        bytes32 indexed policyId,
        uint256 oldValue,
        uint256 newValue
    );

    event EmergencyWithdrawal(
        address indexed recipient,
        uint256 amount,
        address indexed authorizedBy
    );

    // ============ Core Functions ============

    function submitClaim(
        CoverageCategory category,
        uint256 requestedAmount,
        string calldata descriptionURI
    ) external returns (uint256 claimId);

    function updateClaimState(uint256 claimId, ClaimState newState) external;

    function reviewAndApproveClaim(
        uint256 claimId,
        uint256 approvedAmount,
        string calldata auditRecordURI
    ) external;

    function rejectClaim(uint256 claimId, string calldata reason) external;

    function executePayout(uint256 claimId) external;

    // ============ Funding Functions ============

    function fundReserve(FundingSource source, uint256 amount) external;

    function emergencyWithdrawal(address to, uint256 amount) external;

    // ============ Governance Controls ============

    function setMaxPayoutPerClaim(uint256 _maxPayout) external;

    function setGlobalUtilizationLimit(uint256 _limitBasisPoints) external;

    function setAllocationPercentage(uint256 _percentage) external;

    function setCoverageEnabled(CoverageCategory category, bool enabled) external;

    function setPayoutTimelock(uint256 _timelock) external;

    // ============ View Functions ============

    function reserveToken() external view returns (IERC20);

    function getReserveBalance() external view returns (uint256);

    function getUtilizationRatio() external view returns (uint256);

    function getClaim(uint256 claimId) external view returns (Claim memory);

    function getClaimCount() external view returns (uint256);

    function getActiveClaims() external view returns (uint256[] memory);

    function getFundingHistory(
        uint256 offset,
        uint256 limit
    ) external view returns (FundingRecord[] memory);

    function getFundingTotalBySource(FundingSource source) external view returns (uint256);

    function getReserveMetrics() external view returns (ReserveMetrics memory);

    function isCoverageEnabled(CoverageCategory category) external view returns (bool);

    function getMaxPayoutPerClaim() external view returns (uint256);

    function getGlobalUtilizationLimit() external view returns (uint256);

    function getAllocationPercentage() external view returns (uint256);

    function getPayoutTimelock() external view returns (uint256);
}
