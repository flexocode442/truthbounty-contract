// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/ResolverRoleTimelock.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IReputationOracle.sol";
import "./IReputationUpdateEngine.sol";
import "./governance/GovernanceOwnable.sol";
import "./interfaces/ITruthBountyEvents.sol";

/**
 * @title TruthBountyWeighted
 * @notice Enhanced TruthBounty contract with reputation-weighted staking
 * @dev Integrates reputation scores to calculate effective voting power
 *
 * Key Enhancements:
 * - Reputation-weighted voting power
 * - Deterministic effective stake calculation
 * - Prevents low-reputation dominance
 * - Maintains backward compatibility with equal-weight fallback
 */
contract TruthBountyWeighted is ResolverRoleTimelock, ReentrancyGuard, Pausable, GovernanceOwnable, ITruthBountyEvents {
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============ Protocol Constants ============

    /// @notice Fixed-point precision used by token amounts and reputation scores.
    uint256 public constant TOKEN_DECIMALS_MULTIPLIER = 10 ** 18;

    /// @notice Base multiplier for reputation scaling (1e18 = 100%).
    uint256 public constant BASE_MULTIPLIER = TOKEN_DECIMALS_MULTIPLIER;

    /// @notice Denominator for percentage-based governance parameters.
    uint256 public constant PERCENT_DENOMINATOR = 100;

    function _percentOf(uint256 value, uint256 percent) internal pure returns (uint256) {
        return Math.mulDiv(value, percent, PERCENT_DENOMINATOR);
    }

    /// @notice Default verification window for new claims.
    uint256 public constant DEFAULT_VERIFICATION_WINDOW_DURATION = 7 days;

    /// @notice Governance bounds for verification window duration.
    uint256 public constant MIN_VERIFICATION_WINDOW_DURATION = 1 days;
    uint256 public constant MAX_VERIFICATION_WINDOW_DURATION = 30 days;

    /// @notice Default minimum verifier stake amount.
    uint256 public constant DEFAULT_MIN_STAKE_AMOUNT = 100 * TOKEN_DECIMALS_MULTIPLIER;

    /// @notice Default settlement threshold percentage.
    uint256 public constant DEFAULT_SETTLEMENT_THRESHOLD_PERCENT = 60;

    /// @notice Default share of slashed stake distributed to winners.
    uint256 public constant DEFAULT_REWARD_PERCENT = 80;

    /// @notice Default percentage of losing raw stake that is slashed.
    uint256 public constant DEFAULT_SLASH_PERCENT = 20;

    /// @notice Default grace period for reputation updates (2 days).
    uint256 public constant DEFAULT_REPUTATION_UPDATE_GRACE_PERIOD = 2 days;

    /// @notice Minimum reputation update grace period (1 hour).
    uint256 public constant MIN_REPUTATION_UPDATE_GRACE_PERIOD = 1 hours;

    /// @notice Maximum reputation update grace period (30 days).
    uint256 public constant MAX_REPUTATION_UPDATE_GRACE_PERIOD = 30 days;

    /// @notice Minimum reputation score (10% = 0.1x).
    uint256 public constant MIN_REPUTATION_SCORE = TOKEN_DECIMALS_MULTIPLIER / 10;

    /// @notice Maximum reputation score (1000% = 10x).
    uint256 public constant MAX_REPUTATION_SCORE = 10 * TOKEN_DECIMALS_MULTIPLIER;

    /// @notice Default reputation for users without a score (100% = 1.0x).
    uint256 public constant DEFAULT_REPUTATION_SCORE = TOKEN_DECIMALS_MULTIPLIER;
    /// @notice Maximum time allowed between preview and vote before reputation is considered stale (1 hour)
    uint256 public constant MAX_REPUTATION_STALENESS = 1 hours;
    /// @notice Threshold above which a withdrawal is considered "large" and requires a 2-day cooldown (#152)
    uint256 public constant LARGE_WITHDRAWAL_THRESHOLD = 10_000 * TOKEN_DECIMALS_MULTIPLIER;
    /// @notice Canonical indexing schema emitted by this module.
    uint16 public constant EVENT_SCHEMA_VERSION = 1;

    /// @notice Epoch duration for reputation snapshot tracking (7 days) (SC-013)
    uint256 public constant EPOCH_DURATION = 7 days;
    // ============ State Variables ============

    /// @notice Token contract for staking and rewards
    IERC20 public bountyToken;

    /// @notice Reputation oracle for score lookups
    IReputationOracle public reputationOracle;

    /// @notice Reputation update engine for post-settlement reputation changes
    IReputationUpdateEngine public reputationUpdateEngine;

    // ============ Configuration Parameters (Governance-controlled) ============

    uint256 public verificationWindowDuration = DEFAULT_VERIFICATION_WINDOW_DURATION;
    uint256 public confirmationDelay = 1 hours;
    uint256 public minStakeAmount = DEFAULT_MIN_STAKE_AMOUNT;
    uint256 public settlementThresholdPercent = DEFAULT_SETTLEMENT_THRESHOLD_PERCENT;
    uint256 public rewardPercent = DEFAULT_REWARD_PERCENT;
    uint256 public slashPercent = DEFAULT_SLASH_PERCENT;
    uint256 public reputationUpdateGracePeriod = DEFAULT_REPUTATION_UPDATE_GRACE_PERIOD;

    // Governance parameter IDs for reference
    bytes32 public constant GOVERNANCE_PARAM_VERIFICATION_WINDOW = keccak256("VERIFICATION_WINDOW_DURATION");
    bytes32 public constant GOVERNANCE_PARAM_CONFIRMATION_DELAY = keccak256("CONFIRMATION_DELAY");
    bytes32 public constant GOVERNANCE_PARAM_MIN_STAKE = keccak256("MIN_STAKE_AMOUNT");
    bytes32 public constant GOVERNANCE_PARAM_THRESHOLD = keccak256("SETTLEMENT_THRESHOLD_PERCENT");
    bytes32 public constant GOVERNANCE_PARAM_REWARD = keccak256("REWARD_PERCENT");
    bytes32 public constant GOVERNANCE_PARAM_SLASH = keccak256("SLASH_PERCENT");
    bytes32 public constant GOVERNANCE_PARAM_REPUTATION_GRACE_PERIOD = keccak256("REPUTATION_UPDATE_GRACE_PERIOD");

    /// @notice Minimum reputation score (10% = 0.1)
    uint256 public minReputationScore = MIN_REPUTATION_SCORE;

    /// @notice Maximum reputation score (1000% = 10x)
    uint256 public maxReputationScore = MAX_REPUTATION_SCORE;

    /// @notice Default reputation for users without a score (100% = 1.0)
    uint256 public defaultReputationScore = DEFAULT_REPUTATION_SCORE;

    /// @notice Whether weighted staking is enabled
    bool public weightedStakingEnabled = true;

    // ============ Structs ============

    struct Claim {
        uint256 id;
        address submitter;
        string content;
        uint256 createdAt;
        uint256 verificationWindowEnd;
        bool settled;
        uint256 totalWeightedFor;      // Weighted votes for claim (NEW)
        uint256 totalWeightedAgainst;  // Weighted votes against claim (NEW)
        uint256 totalStakeAmount;      // Total raw stake amount
        uint256 totalStakedFor;        // Total raw stake for (support)
        uint256 totalStakedAgainst;    // Total raw stake against
    }

    struct Vote {
        bool voted;
        bool support;
        uint256 stakeAmount;           // Raw stake amount
        uint256 effectiveStake;        // Weighted stake amount (NEW)
        uint256 reputationScore;       // Reputation score at vote time (NEW)
        bool rewardClaimed;
        bool stakeReturned;
        uint256 slashAmount;           // Per-vote slash amount calculated at settlement (prevents double-slash)
        uint256 snapshotTimestamp;     // Block timestamp when snapshot was captured at vote time (SC-013)
        uint256 snapshotEpoch;         // Protocol epoch at vote time (SC-013)
        bytes32 snapshotRoot;          // Merkle root reserved for future proof verification (SC-013)
    }

    struct Verification {
        address verifier;
        uint256 reputationSnapshot;
        uint256 snapshotTimestamp;
        uint256 snapshotEpoch;
        bytes32 snapshotRoot;
        uint256 effectiveStake;
        uint256 stakeAmount;
        bool support;
    }

    struct SettlementResult {
        bool passed;
        uint256 totalRewards;
        uint256 totalSlashed;
        uint256 winnerWeightedStake;   // Changed to weighted (NEW)
        uint256 loserWeightedStake;    // Changed to weighted (NEW)
        uint256 winnerCount;           // Number of winning voters eligible for rewards
        uint256 winnersClaimed;        // Number of winning voters that claimed rewards
        uint256 rewardsClaimed;        // Total rewards already distributed
    }

    struct VerifierStake {
        uint256 totalStaked;
        uint256 activeStakes;
        uint256 exitTime;
    }

    struct ReputationSnapshot {
        uint256 reputationScore;
        uint256 timestamp;
    }

    // ============ Storage Mappings ============

    mapping(uint256 => Claim) public claims;
    mapping(uint256 => SettlementResult) public settlementResults;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(address => VerifierStake) public verifierStakes;
    mapping(uint256 => address[]) private claimVoters;  // Track all voters per claim for settlement
    
    /// @notice Track reputation snapshots for staleness validation: user => (reputationScore, timestamp)
    mapping(address => ReputationSnapshot) public reputationSnapshots;

    uint256 public claimCounter;
    uint256 public totalSlashed;
    uint256 public totalRewarded;

    // ============ Events ============

    event ClaimCreated(
        uint256 indexed claimId,
        address indexed submitter,
        string content,
        uint256 verificationWindowEnd
    );

    event VoteCast(
        uint256 indexed claimId,
        address indexed verifier,
        bool support,
        uint256 rawStake,
        uint256 effectiveStake,
        uint256 reputationScore
    );

    event ClaimSettled(
        uint256 indexed claimId,
        bool passed,
        uint256 totalWeightedFor,
        uint256 totalWeightedAgainst,
        uint256 totalRewards,
        uint256 totalSlashed
    );

    event RewardsDistributed(
        uint256 indexed claimId,
        address indexed verifier,
        uint256 amount
    );

    event StakeSlashed(
        uint256 indexed claimId,
        address indexed verifier,
        uint256 amount
    );

    event StakeDeposited(address indexed verifier, uint256 amount);
    event StakeWithdrawn(address indexed verifier, uint256 amount);
    event ReputationOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ReputationBoundsUpdated(uint256 minScore, uint256 maxScore);
    event ReputationUpdateGracePeriodUpdated(uint256 newGracePeriod);
    event WeightedStakingToggled(bool enabled);
    event DefaultReputationScoreUpdated(uint256 oldScore, uint256 newScore);
    event ReputationSnapshotRecorded(address indexed user, uint256 reputationScore, uint256 timestamp);
    event ReputationStalenessValidated(address indexed user, uint256 expectedReputation, uint256 actualReputation, uint256 maxDrift);
    event ClaimWiped(uint256 indexed claimId, address indexed admin, string reason);
    event ReputationUpdateEngineUpdated(address indexed oldEngine, address indexed newEngine);

    // ============ Errors ============

    error InvalidReputationOracle();
    error InvalidReputationBounds();
    error InvalidReputationUpdateGracePeriod();
    error InvalidReputationUpdateEngine();

    // ============ Constructor ============

    constructor(
        address _bountyToken,
        address _reputationOracle,
        address initialAdmin,
        address _governanceController
    ) {
        require(_bountyToken != address(0), "Invalid token address");
        require(_reputationOracle != address(0), "Invalid oracle address");
        require(initialAdmin != address(0), "Invalid admin address");
        
        bountyToken = IERC20(_bountyToken);
        reputationOracle = IReputationOracle(_reputationOracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        
        _setRoleAdmin(RESOLVER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(TREASURY_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        
        // Initialize governance
        _initializeGovernance(_governanceController, initialAdmin, initialAdmin);
    }

    function _resolverRole() internal pure override returns (bytes32) {
        return RESOLVER_ROLE;
    }

    function grantRole(bytes32 role, address account) public override(AccessControl, ResolverRoleTimelock) {
        ResolverRoleTimelock.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override(AccessControl, ResolverRoleTimelock) {
        ResolverRoleTimelock.revokeRole(role, account);
    }

    // ============ Core Functions ============

    /**
     * @notice Create a new claim for verification
     * @param content IPFS hash or content reference
     * @return claimId The ID of the newly created claim
     */
    function createClaim(string memory content) external whenNotPaused returns (uint256) {
        uint256 claimId = claimCounter++;
        uint256 verificationWindowEnd = block.timestamp + verificationWindowDuration;

        claims[claimId] = Claim({
            id: claimId,
            submitter: msg.sender,
            content: content,
            createdAt: block.timestamp,
            verificationWindowEnd: verificationWindowEnd,
            settled: false,
            totalWeightedFor: 0,
            totalWeightedAgainst: 0,
            totalStakeAmount: 0,
            totalStakedFor: 0,
            totalStakedAgainst: 0
        });

        emit ClaimCreated(claimId, msg.sender, content, verificationWindowEnd);
        emit ClaimCreatedV1(
            claimId,
            msg.sender,
            keccak256(bytes(content)),
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
        return claimId;
    }

    /**
     * @notice Stake tokens to participate in verification
     * @param amount Amount of tokens to stake
     * @dev Uses msg.sender (not tx.origin) to prevent phishing attacks where a malicious
     *      contract could trick users into staking on their behalf. tx.origin is never used
     *      for authorization in this contract.
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        // #191: Explicitly use msg.sender (not tx.origin) to prevent phishing risk.
        // Callers must be the direct transaction sender.
        require(msg.sender == tx.origin, "Direct calls only: no contract intermediaries");
        require(amount >= minStakeAmount, "Stake below minimum");
        require(bountyToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        verifierStakes[msg.sender].totalStaked += amount;

        emit StakeDeposited(msg.sender, amount);
        emit StakeDepositedV1(
            msg.sender,
            amount,
            verifierStakes[msg.sender].totalStaked,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    /**
     * @notice Vote on a claim with reputation-weighted stake
     * @param claimId The ID of the claim to vote on
     * @param support true for pass, false for fail
     * @param stakeAmount Amount of stake to commit to this vote
     */
    function vote(
        uint256 claimId,
        bool support,
        uint256 stakeAmount
    ) external nonReentrant whenNotPaused {
        _vote(claimId, support, stakeAmount, 0, 0);
    }

    /**
     * @notice Vote on a claim with reputation staleness validation
     * @param claimId The ID of the claim to vote on
     * @param support true for pass, false for fail
     * @param stakeAmount Amount of stake to commit to this vote
     * @param expectedReputation The reputation score expected (from preview), 0 to skip validation
     * @param maxReputationDrift Maximum allowed percentage change in reputation (in basis points, 0-10000), 0 for no limit
     */
    function voteWithValidation(
        uint256 claimId,
        bool support,
        uint256 stakeAmount,
        uint256 expectedReputation,
        uint256 maxReputationDrift
    ) external nonReentrant whenNotPaused {
        _vote(claimId, support, stakeAmount, expectedReputation, maxReputationDrift);
    }

    /**
     * @notice Internal vote function with optional staleness validation
     * @param claimId The claim ID
     * @param support Vote direction
     * @param stakeAmount Stake amount
     * @param expectedReputation Expected reputation (0 = skip validation)
     * @param maxReputationDrift Max allowed drift in basis points (0 = no limit)
     */
    function _vote(
        uint256 claimId,
        bool support,
        uint256 stakeAmount,
        uint256 expectedReputation,
        uint256 maxReputationDrift
    ) internal {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(block.timestamp < claim.verificationWindowEnd, "Verification window closed");
        require(!claim.settled, "Claim already settled");
        require(!votes[claimId][msg.sender].voted, "Already voted");
        require(stakeAmount >= minStakeAmount, "Stake below minimum");
        require(
            verifierStakes[msg.sender].totalStaked >=
                verifierStakes[msg.sender].activeStakes + stakeAmount,
            "Insufficient available stake"
        );

        // Calculate weighted stake based on reputation
        uint256 reputationScore = _getReputationScore(msg.sender);
        
        // Validate reputation staleness if expected reputation is provided
        if (expectedReputation > 0) {
            _validateReputationFreshness(msg.sender, reputationScore, expectedReputation, maxReputationDrift);
        }
        
        uint256 effectiveStake = _calculateEffectiveStake(stakeAmount, reputationScore);

        // Lock the raw stake
        verifierStakes[msg.sender].activeStakes += stakeAmount;

        // Record the vote with both raw and effective stakes and immutable reputation snapshot (SC-013)
        votes[claimId][msg.sender] = Vote({
            voted: true,
            support: support,
            stakeAmount: stakeAmount,
            effectiveStake: effectiveStake,
            reputationScore: reputationScore,
            rewardClaimed: false,
            stakeReturned: false,
            slashAmount: 0,
            snapshotTimestamp: block.timestamp,
            snapshotEpoch: block.timestamp / EPOCH_DURATION,
            snapshotRoot: bytes32(0)
        });

        // Store reputation snapshot for future validation
        reputationSnapshots[msg.sender] = ReputationSnapshot({
            reputationScore: reputationScore,
            timestamp: block.timestamp
        });
        emit ReputationSnapshotRecorded(msg.sender, reputationScore, block.timestamp);

        // Track this voter for settlement calculations
        claimVoters[claimId].push(msg.sender);

        // Update claim totals with WEIGHTED stakes
        if (support) {
            claim.totalWeightedFor += effectiveStake;
            claim.totalStakedFor += stakeAmount;
        } else {
            claim.totalWeightedAgainst += effectiveStake;
            claim.totalStakedAgainst += stakeAmount;
        }
        claim.totalStakeAmount += stakeAmount; // Still track raw stake total

        emit VoteCast(claimId, msg.sender, support, stakeAmount, effectiveStake, reputationScore);
        emit VerificationSubmittedV1(
            claimId,
            msg.sender,
            support,
            stakeAmount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    /**
     * @notice Settle a claim after verification window closes
     * @param claimId The ID of the claim to settle
     */
    function settleClaim(uint256 claimId) external nonReentrant whenNotPaused {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(block.timestamp >= claim.verificationWindowEnd + confirmationDelay, "Confirmation delay pending");
        require(!claim.settled, "Claim already settled");
        require(claim.totalStakeAmount > 0, "No votes cast");

        claim.settled = true;

        // Determine outcome based on WEIGHTED votes. Exact ties are resolved as
        // a refund-only outcome so no side is left unable to recover stake.
        bool isTie = claim.totalWeightedFor == claim.totalWeightedAgainst && claim.totalWeightedFor > 0;
        bool passed = isTie ? false : _determineOutcome(claim.totalWeightedFor, claim.totalWeightedAgainst);

        // Calculate rewards and slashing
        (uint256 rewardAmount, uint256 slashedAmount) = _calculateSettlement(
            claimId,
            passed,
            isTie
        );

        emit ClaimSettled(
            claimId,
            passed,
            claim.totalWeightedFor,
            claim.totalWeightedAgainst,
            rewardAmount,
            slashedAmount
        );
        emit ClaimResolvedV1(
            claimId,
            msg.sender,
            passed,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
        emit ClaimFinalizedV1(
            claimId,
            msg.sender,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    /**
     * @notice Claim rewards for winning a vote
     * @param claimId The ID of the settled claim
     */
    function claimSettlementRewards(uint256 claimId) external nonReentrant whenNotPaused {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(claim.settled, "Claim not settled");

        Vote storage vote = votes[claimId][msg.sender];
        require(vote.voted, "No vote cast");
        require(!vote.rewardClaimed, "Rewards already claimed");

        SettlementResult storage settlement = settlementResults[claimId];
        bool isTie = _isTieSettlement(settlement);

        if (isTie) {
            require(!vote.stakeReturned, "Stake already returned");

            vote.rewardClaimed = true;
            vote.stakeReturned = true;
            verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;
            require(bountyToken.transfer(msg.sender, vote.stakeAmount), "Stake transfer failed");
            emit StakeWithdrawn(msg.sender, vote.stakeAmount);
            emit StakeWithdrawnV1(
                msg.sender,
                vote.stakeAmount,
                verifierStakes[msg.sender].totalStaked,
                uint64(block.timestamp),
                EVENT_SCHEMA_VERSION
            );
            return;
        }

        require(settlement.winnerWeightedStake > 0, "No winners");

        // Check if verifier was on the winning side
        bool isWinner = (vote.support == settlement.passed);
        require(isWinner, "Not a winner");

        // Calculate proportional reward based on EFFECTIVE stake. Integer division can
        // leave a remainder, so assign any undistributed dust to the final winning
        // claimant to ensure totalRewards is fully paid out.
        uint256 reward = (vote.effectiveStake * settlement.totalRewards) / settlement.winnerWeightedStake;

        settlement.winnersClaimed += 1;
        if (settlement.winnersClaimed == settlement.winnerCount) {
            reward = settlement.totalRewards - settlement.rewardsClaimed;
        }
        settlement.rewardsClaimed += reward;

        // Mark as claimed
        vote.rewardClaimed = true;

        // Transfer reward
        if (reward > 0) {
            require(bountyToken.transfer(msg.sender, reward), "Reward transfer failed");
            emit RewardsDistributed(claimId, msg.sender, reward);
            emit RewardClaimedV1(
                claimId,
                msg.sender,
                reward,
                uint64(block.timestamp),
                EVENT_SCHEMA_VERSION
            );
        }

        // Return stake (winners get full RAW stake back)
        if (!vote.stakeReturned) {
            vote.stakeReturned = true;
            verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;
            require(bountyToken.transfer(msg.sender, vote.stakeAmount), "Stake transfer failed");
            emit StakeWithdrawn(msg.sender, vote.stakeAmount);
            emit StakeWithdrawnV1(
                msg.sender,
                vote.stakeAmount,
                verifierStakes[msg.sender].totalStaked,
                uint64(block.timestamp),
                EVENT_SCHEMA_VERSION
            );
        }
    }

    /**
     * @notice Withdraw stake after settlement (for losers)
     * @param claimId The ID of the settled claim
     */
    function withdrawSettledStake(uint256 claimId) external nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(claim.settled, "Claim not settled");

        Vote storage vote = votes[claimId][msg.sender];
        require(vote.voted, "No vote cast");
        require(!vote.stakeReturned, "Stake already returned");

        SettlementResult storage settlement = settlementResults[claimId];
        bool isTie = _isTieSettlement(settlement);

        if (isTie) {
            vote.stakeReturned = true;
            vote.rewardClaimed = true;
            verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;
            require(bountyToken.transfer(msg.sender, vote.stakeAmount), "Stake transfer failed");
            emit StakeWithdrawn(msg.sender, vote.stakeAmount);
            emit StakeWithdrawnV1(
                msg.sender,
                vote.stakeAmount,
                verifierStakes[msg.sender].totalStaked,
                uint64(block.timestamp),
                EVENT_SCHEMA_VERSION
            );
            return;
        }

        bool isWinner = (vote.support == settlement.passed);

        uint256 stakeToReturn;
        uint256 slashAmount = vote.slashAmount; // Use pre-calculated slash amount (no recalculation)

        if (isWinner) {
            stakeToReturn = vote.stakeAmount;
        } else {
            // Losers get stake back minus slashing (pre-calculated at settlement)
            stakeToReturn = vote.stakeAmount - slashAmount;

            emit StakeSlashed(claimId, msg.sender, slashAmount);
            emit SlashExecutedV1(
                claimId,
                msg.sender,
                keccak256("LOSING_VERIFICATION_POSITION"),
                slashAmount,
                uint64(block.timestamp),
                EVENT_SCHEMA_VERSION
            );
        }

        vote.stakeReturned = true;
        verifierStakes[msg.sender].activeStakes -= vote.stakeAmount;

        if (!isWinner) {
            verifierStakes[msg.sender].totalStaked -= slashAmount;
        }

        if (stakeToReturn > 0) {
            require(bountyToken.transfer(msg.sender, stakeToReturn), "Stake transfer failed");
            emit StakeWithdrawn(msg.sender, stakeToReturn);
            emit StakeWithdrawnV1(
                msg.sender,
                stakeToReturn,
                verifierStakes[msg.sender].totalStaked,
                uint64(block.timestamp),
                EVENT_SCHEMA_VERSION
            );
        }
    }

    /**
     * @notice Withdraw available stake (not locked in active claims)
     * @dev #152: Large withdrawals (>= LARGE_WITHDRAWAL_THRESHOLD) require a 2-day cooldown
     *      to prevent whale exit attacks. Small withdrawals proceed immediately.
     */
    function withdrawStake(uint256 amount) external nonReentrant whenNotPaused {
        VerifierStake storage stake = verifierStakes[msg.sender];
        require(
            stake.totalStaked >= stake.activeStakes + amount,
            "Insufficient available stake"
        );

        // #152: Apply withdrawal delay only for large amounts to mitigate whale exit risk
        if (amount >= LARGE_WITHDRAWAL_THRESHOLD) {
            if (stake.exitTime == 0) {
                // Initiate the cooldown clock for this large withdrawal
                stake.exitTime = block.timestamp;
                revert("Large withdrawal initiated. Please wait 2 days cooldown.");
            }
            // Ensure the 2-day cooldown window has passed
            require(block.timestamp >= stake.exitTime + 2 days, "Cooldown active");
            // Reset the exit clock after successful large withdrawal
            stake.exitTime = 0;
        }

        stake.totalStaked -= amount;
        require(bountyToken.transfer(msg.sender, amount), "Transfer failed");

        emit StakeWithdrawn(msg.sender, amount);
        emit StakeWithdrawnV1(
            msg.sender,
            amount,
            verifierStakes[msg.sender].totalStaked,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }


    // ============ Internal Helper Functions ============

    /**
     * @notice Get the reputation score for a user, considering grace period restrictions
     * @param user The address to query
     * @param claimCreatedAt Timestamp when the claim was created
     * @return score The effective reputation score (after grace period check)
     * @dev If reputation was updated within grace period before claim creation, returns default score
     */
    function _getReputationScoreWithGracePeriod(
        address user,
        uint256 claimCreatedAt
    ) internal view returns (uint256 score) {
        if (!weightedStakingEnabled) {
            return BASE_MULTIPLIER;
        }

        // Try to get the oracle's active status
        try reputationOracle.isActive() returns (bool active) {
            if (!active) {
                return defaultReputationScore;
            }
        } catch {
            return defaultReputationScore;
        }

        // Try to get the last update timestamp
        uint256 lastUpdateTime = 0;
        try reputationOracle.getLastReputationUpdate(user) returns (uint256 timestamp) {
            lastUpdateTime = timestamp;
        } catch {
            // Oracle doesn't support getLastReputationUpdate, proceed without grace period check
            lastUpdateTime = 0;
        }

        // Check if reputation was updated within grace period
        // Grace period window: [claimCreatedAt - gracePeriod, claimCreatedAt + gracePeriod]
        if (lastUpdateTime > 0) {
            uint256 timeSinceClaimCreation = lastUpdateTime > claimCreatedAt
                ? lastUpdateTime - claimCreatedAt
                : claimCreatedAt - lastUpdateTime;

            // If reputation update happened within grace period of claim creation, use default
            if (timeSinceClaimCreation <= reputationUpdateGracePeriod) {
                return defaultReputationScore;
            }
        }

        // Get the actual reputation score
        try reputationOracle.getReputationScore(user) returns (uint256 reputationScore) {
            if (reputationScore == 0) {
                return defaultReputationScore;
            }
            return _applyReputationBounds(reputationScore);
        } catch {
            return defaultReputationScore;
        }
    }

    /**
     * @notice Get reputation score with bounds and fallback
     * @param user The address to query
     * @return score The bounded reputation score
     */
    function _getReputationScore(address user) internal view returns (uint256 score) {
        if (!weightedStakingEnabled) {
            return BASE_MULTIPLIER;
        }

        // Try to get score from oracle
        try reputationOracle.isActive() returns (bool active) {
            if (!active) {
                return defaultReputationScore;
            }
        } catch {
            return defaultReputationScore;
        }

        try reputationOracle.getReputationScore(user) returns (uint256 reputationScore) {
            if (reputationScore == 0) {
                return defaultReputationScore;
            }
            return _applyReputationBounds(reputationScore);
        } catch {
            return defaultReputationScore;
        }
    }

    /**
     * @notice Apply min/max bounds to reputation score
     */
    function _applyReputationBounds(uint256 score) internal view returns (uint256) {
        if (score < minReputationScore) return minReputationScore;
        if (score > maxReputationScore) return maxReputationScore;
        return score;
    }

    /**
     * @notice Validate that reputation hasn't staled significantly
     * @param user The user address
     * @param currentReputation The current reputation score
     * @param expectedReputation The expected reputation from preview
     * @param maxDrift Maximum allowed drift in basis points (0-10000)
     * @dev Reverts if reputation has drifted more than allowed or is too old
     */
    function _validateReputationFreshness(
        address user,
        uint256 currentReputation,
        uint256 expectedReputation,
        uint256 maxDrift
    ) internal {
        ReputationSnapshot memory lastSnapshot = reputationSnapshots[user];
        
        // If no previous snapshot, this is the first preview - allow it
        if (lastSnapshot.timestamp == 0) {
            return;
        }
        
        // Check if reputation has changed more than the allowed drift
        if (maxDrift > 0) {
            // Calculate percentage change: (|current - expected| / expected) * 10000
            uint256 absoluteDiff = currentReputation > expectedReputation 
                ? currentReputation - expectedReputation 
                : expectedReputation - currentReputation;
            
            uint256 driftPercent = (absoluteDiff * 10000) / expectedReputation;
            require(driftPercent <= maxDrift, "Reputation changed more than allowed");
        }
        
        // Check if reputation is too stale (timestamp-based)
        uint256 timeSinceSnapshot = block.timestamp - lastSnapshot.timestamp;
        require(timeSinceSnapshot <= MAX_REPUTATION_STALENESS, "Reputation too stale");
        
        // Emit validation event
        emit ReputationStalenessValidated(user, expectedReputation, currentReputation, maxDrift);
    }

    /**
     * @notice Calculate effective stake from raw stake and reputation
     * @param stakeAmount Raw stake amount
     * @param reputationScore Reputation score (scaled by 1e18)
     * @return effectiveStake Weighted stake amount, capped at 10x raw stake (#154)
     * @dev The 10x cap (MAX_REPUTATION_SCORE = 10e18) prevents whale reputation dominance.
     *      Even if the oracle returns a score above 10x, effectiveStake cannot exceed 10 * stakeAmount.
     */
    function _calculateEffectiveStake(
        uint256 stakeAmount,
        uint256 reputationScore
    ) internal pure returns (uint256 effectiveStake) {
        effectiveStake = (stakeAmount * reputationScore) / BASE_MULTIPLIER;
        // #154: Explicitly cap effectiveStake to 10x raw stake to prevent excessive dominance
        uint256 maxEffective = stakeAmount * 10;
        if (effectiveStake > maxEffective) {
            effectiveStake = maxEffective;
        }
    }

    /**
     * @notice Determine outcome based on weighted votes
     */
    function _determineOutcome(
        uint256 weightedFor,
        uint256 weightedAgainst
    ) internal view returns (bool) {
        uint256 totalWeighted = weightedFor + weightedAgainst;
        if (totalWeighted == 0) return false;

        uint256 forPercent = (weightedFor * PERCENT_DENOMINATOR) / totalWeighted;
        return forPercent >= settlementThresholdPercent;
    }

    /**
     * @notice Calculate settlement based on weighted stakes
     * @dev Assigns per-vote slash amounts to prevent double-slashing
     */
    function _calculateSettlement(
        uint256 claimId,
        bool passed,
        bool isTie
    ) internal returns (uint256 rewardAmount, uint256 slashedAmount) {
        Claim storage claim = claims[claimId];

        if (isTie) {
            settlementResults[claimId] = SettlementResult({
                passed: false,
                totalRewards: 0,
                totalSlashed: 0,
                winnerWeightedStake: 0,
                loserWeightedStake: 0,
                winnerCount: 0,
                winnersClaimed: 0,
                rewardsClaimed: 0
            });

            // SC-008: Apply neutral reputation updates for all voters in a tie
            _applyReputationUpdates(claimId, /* isTie */ true);

            return (0, 0);
        }

        // Use WEIGHTED stakes for determining winner/loser totals
        uint256 winnerWeightedStake = passed ? claim.totalWeightedFor : claim.totalWeightedAgainst;
        uint256 loserWeightedStake = passed ? claim.totalWeightedAgainst : claim.totalWeightedFor;

        // Exact total RAW stake from losing side (pre-calculated during voting)
        uint256 loserRawStake = passed ? claim.totalStakedAgainst : claim.totalStakedFor;

        // Slash the configured percentage of losing raw stake.
        slashedAmount = _percentOf(loserRawStake, slashPercent);
        // Calculate and assign per-vote slash amounts, returns total slashed
        slashedAmount = _assignPerVoteSlashes(claimId, passed);

        // The configured reward share of slashed stake goes to winners.
        rewardAmount = _percentOf(slashedAmount, rewardPercent);

        totalSlashed += slashedAmount;
        totalRewarded += rewardAmount;

        settlementResults[claimId] = SettlementResult({
            passed: passed,
            totalRewards: rewardAmount,
            totalSlashed: slashedAmount,
            winnerWeightedStake: winnerWeightedStake,
            loserWeightedStake: loserWeightedStake,
            winnerCount: _countWinners(claimId, passed),
            winnersClaimed: 0,
            rewardsClaimed: 0
        });

        // SC-008: Apply reputation updates after settlement is fully recorded
        _applyReputationUpdates(claimId, /* isTie */ false);
    }

    /**
     * @notice Count voters on the winning side for remainder-safe reward distribution
     */
    function _countWinners(uint256 claimId, bool passed) internal view returns (uint256 count) {
        address[] storage voters = claimVoters[claimId];

        for (uint256 i = 0; i < voters.length; i++) {
            Vote storage vote = votes[claimId][voters[i]];
            if (vote.support == passed) {
                count += 1;
            }
        }
    }

    /**
     * @notice Check whether settlement should be treated as a tie refund
     */
    function _isTieSettlement(SettlementResult storage settlement) internal view returns (bool) {
        return
            settlement.totalRewards == 0 &&
            settlement.totalSlashed == 0 &&
            settlement.winnerWeightedStake == 0 &&
            settlement.loserWeightedStake == 0;
    }

    /**
     * @notice Assign per-vote slash amounts to each loser
     * @dev Iterates through all voters and stores slash amount in Vote struct for losers
     * @return totalSlashed Sum of all slash amounts
     */
    function _assignPerVoteSlashes(
        uint256 claimId,
        bool passed
    ) internal returns (uint256 totalSlashed) {
        address[] storage voters = claimVoters[claimId];
        
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            Vote storage vote = votes[claimId][voter];
            
            bool isLoser = (vote.support != passed);
            
            if (isLoser) {
                // Calculate slash as the configured percentage of raw stake.
                uint256 slashAmount = _percentOf(vote.stakeAmount, slashPercent);
                vote.slashAmount = slashAmount;
                totalSlashed += slashAmount;
            } else {
                // Winners are not slashed
                vote.slashAmount = 0;
            }

            // Reputation updates handled in _calculateSettlement after this returns.
        }
    }

    // ============ SC-008: Reputation Update Integration ============

    /**
     * @notice Apply reputation updates for all voters after settlement
     * @param claimId The settled claim ID
     * @param isTie   Whether the settlement resulted in a tie
     * @dev Winners (or all voters in a tie) receive correct-verification updates.
     *      Losers receive incorrect-verification penalties.
     *      The claim submitter receives a neutral disputed-claim update.
     *      If no update engine is configured, this is a no-op.
     */
    function _applyReputationUpdates(uint256 claimId, bool isTie) internal {
        if (address(reputationUpdateEngine) == address(0)) return;

        SettlementResult storage settlement = settlementResults[claimId];
        address[] storage voters = claimVoters[claimId];

        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            if (reputationUpdateEngine.isClaimProcessed(voter, claimId)) continue;

            IReputationUpdateEngine.UpdateReason reason;

            if (isTie) {
                reason = IReputationUpdateEngine.UpdateReason.DISPUTED_CLAIM;
            } else {
                bool isWinner = (votes[claimId][voter].support == settlement.passed);
                reason = isWinner
                    ? IReputationUpdateEngine.UpdateReason.CORRECT_VERIFICATION
                    : IReputationUpdateEngine.UpdateReason.INCORRECT_VERIFICATION;
            }

            reputationUpdateEngine.updateReputation(IReputationUpdateEngine.ReputationUpdate({
                verifier: voter,
                delta: 0,
                reason: reason,
                claimId: claimId
            }));
        }

        // Also update the claim submitter's reputation as a disputed outcome
        // so submitters cannot spam claims without reputation consequence.
        address submitter = claims[claimId].submitter;
        if (submitter != address(0) && !reputationUpdateEngine.isClaimProcessed(submitter, claimId)) {
            reputationUpdateEngine.updateReputation(IReputationUpdateEngine.ReputationUpdate({
                verifier: submitter,
                delta: 0,
                reason: IReputationUpdateEngine.UpdateReason.DISPUTED_CLAIM,
                claimId: claimId
            }));
        }
    }

    /**
     * @notice Set the reputation update engine address
     * @param _newEngine Address of the ReputationUpdateEngine contract
     */
    function setReputationUpdateEngine(address _newEngine) external onlyRole(ADMIN_ROLE) {
        if (_newEngine == address(0)) revert InvalidReputationUpdateEngine();

        address oldEngine = address(reputationUpdateEngine);
        reputationUpdateEngine = IReputationUpdateEngine(_newEngine);

        emit ReputationUpdateEngineUpdated(oldEngine, _newEngine);
    }

    // ============ Admin Functions ============

    /**
     * @notice Emergency function to wipe a claim containing illegal or harmful content
     * @param claimId The ID of the claim to wipe
     * @param reason Human-readable reason for wiping (e.g. "DMCA", "CSAM", "court order")
     * @dev Refunds all raw stakes to voters before clearing the claim. Only callable by ADMIN_ROLE.
     *      This is a legal/safety emergency measure — use only when required.
     */
    function wipeClaim(uint256 claimId, string calldata reason) external onlyRole(ADMIN_ROLE) nonReentrant {
        Claim storage claim = claims[claimId];
        require(claim.submitter != address(0), "Claim does not exist");
        require(!claim.settled, "Claim already settled");
        require(bytes(reason).length > 0, "Reason required");

        // Refund all voters their raw stake before wiping
        address[] storage voters = claimVoters[claimId];
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            Vote storage v = votes[claimId][voter];
            if (v.voted && !v.stakeReturned && v.stakeAmount > 0) {
                v.stakeReturned = true;
                v.rewardClaimed = true;
                verifierStakes[voter].activeStakes -= v.stakeAmount;
                require(bountyToken.transfer(voter, v.stakeAmount), "Stake refund failed");
                emit StakeWithdrawn(voter, v.stakeAmount);
            }
        }

        // Mark claim as settled (prevents further interaction) and clear content
        claim.settled = true;
        claim.content = "";

        emit ClaimWiped(claimId, msg.sender, reason);
    }

    /**
     * @notice Update the reputation oracle
     */
    function setReputationOracle(address _newOracle) external onlyRole(ADMIN_ROLE) {
        if (_newOracle == address(0)) revert InvalidReputationOracle();

        address oldOracle = address(reputationOracle);
        reputationOracle = IReputationOracle(_newOracle);

        emit ReputationOracleUpdated(oldOracle, _newOracle);
    }

    /**
     * @notice Update reputation score bounds
     */
    function setReputationBounds(uint256 _minScore, uint256 _maxScore) external onlyRole(ADMIN_ROLE) {
        if (_minScore == 0 || _minScore >= _maxScore) revert InvalidReputationBounds();

        minReputationScore = _minScore;
        maxReputationScore = _maxScore;

        emit ReputationBoundsUpdated(_minScore, _maxScore);
    }

    /**
     * @notice Toggle weighted staking on/off
     */
    function setWeightedStakingEnabled(bool _enabled) external onlyRole(ADMIN_ROLE) {
        weightedStakingEnabled = _enabled;
        emit WeightedStakingToggled(_enabled);
    }

    /**
     * @notice Set default reputation score
     */
    function setDefaultReputationScore(uint256 _defaultScore) external onlyRole(ADMIN_ROLE) {
        require(_defaultScore > 0, "Invalid default");
        uint256 oldScore = defaultReputationScore;
        defaultReputationScore = _defaultScore;
        emit DefaultReputationScoreUpdated(oldScore, _defaultScore);
    }

    // ============ Governance Parameter Updates ============
    
    /**
     * @notice Update verification window duration (governance or admin)
     * @param newDuration New duration in seconds
     */
    function setVerificationWindowDuration(uint256 newDuration) external onlyGovernanceOrAdmin {
        require(
            newDuration >= MIN_VERIFICATION_WINDOW_DURATION
                && newDuration <= MAX_VERIFICATION_WINDOW_DURATION,
            "Invalid duration"
        );
        
        uint256 oldDuration = verificationWindowDuration;
        verificationWindowDuration = newDuration;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_VERIFICATION_WINDOW, oldDuration, newDuration);
    }

    /**
     * @notice Update confirmation delay (governance or admin)
     * @param newDelay New delay in seconds
     */
    function setConfirmationDelay(uint256 newDelay) external onlyGovernanceOrAdmin {
        require(newDelay >= 5 minutes && newDelay <= 7 days, "Invalid duration");
        
        uint256 oldDelay = confirmationDelay;
        confirmationDelay = newDelay;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_CONFIRMATION_DELAY, oldDelay, newDelay);
    }
    
    /**
     * @notice Update minimum stake amount (governance or admin)
     * @param newAmount New minimum stake amount
     * @dev Prevents Denial of Service by ensuring minStakeAmount does not exceed token supply
     */
    function setMinStakeAmount(uint256 newAmount) external onlyGovernanceOrAdmin {
        require(newAmount > 0, "Invalid amount");
        require(newAmount <= bountyToken.totalSupply(), "Min stake exceeds token supply");
        
        uint256 oldAmount = minStakeAmount;
        minStakeAmount = newAmount;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_MIN_STAKE, oldAmount, newAmount);
    }
    
    /**
     * @notice Update settlement threshold percentage (governance or admin)
     * @param newThreshold New threshold (1-100)
     */
    function setSettlementThresholdPercent(uint256 newThreshold) external onlyGovernanceOrAdmin {
        require(newThreshold > 0 && newThreshold <= PERCENT_DENOMINATOR, "Invalid threshold");
        
        uint256 old = settlementThresholdPercent;
        settlementThresholdPercent = newThreshold;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_THRESHOLD, old, newThreshold);
    }
    
    /**
     * @notice Update reward percentage (governance or admin)
     * @param newPercent New reward percent (1-100)
     */
    function setRewardPercent(uint256 newPercent) external onlyGovernanceOrAdmin {
        require(newPercent > 0 && newPercent <= PERCENT_DENOMINATOR, "Invalid percent");
        
        uint256 old = rewardPercent;
        rewardPercent = newPercent;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_REWARD, old, newPercent);
    }
    
    /**
     * @notice Update slash percentage (governance or admin)
     * @param newPercent New slash percent (1-100)
     */
    function setSlashPercent(uint256 newPercent) external onlyGovernanceOrAdmin {
        require(newPercent > 0 && newPercent <= PERCENT_DENOMINATOR, "Invalid percent");
        
        uint256 old = slashPercent;
        slashPercent = newPercent;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_SLASH, old, newPercent);
    }

    /**
     * @notice Update reputation update grace period (governance or admin)
     * @param newGracePeriod New grace period in seconds
     * @dev Grace period prevents last-minute reputation boosts from being used in voting
     */
    function setReputationUpdateGracePeriod(uint256 newGracePeriod) external onlyGovernanceOrAdmin {
        if (newGracePeriod < MIN_REPUTATION_UPDATE_GRACE_PERIOD || 
            newGracePeriod > MAX_REPUTATION_UPDATE_GRACE_PERIOD) {
            revert InvalidReputationUpdateGracePeriod();
        }
        
        uint256 old = reputationUpdateGracePeriod;
        reputationUpdateGracePeriod = newGracePeriod;
        
        emit ParameterUpdatedByGovernance(GOVERNANCE_PARAM_REPUTATION_GRACE_PERIOD, old, newGracePeriod);
        emit ReputationUpdateGracePeriodUpdated(newGracePeriod);
    }

    // ============ View Functions ============

    function getClaim(uint256 claimId) external view returns (Claim memory) {
        return claims[claimId];
    }

    function getVote(uint256 claimId, address verifier) external view returns (Vote memory) {
        return votes[claimId][verifier];
    }

    function getVerifierStake(address verifier) external view returns (VerifierStake memory) {
        return verifierStakes[verifier];
    }

    function getClaimVoterCount(uint256 claimId) external view returns (uint256) {
        return claimVoters[claimId].length;
    }

    function getClaimVoterAt(uint256 claimId, uint256 index) external view returns (address) {
        return claimVoters[claimId][index];
    }

    function getVerificationWeight(uint256 claimId, address verifier) external view returns (uint256) {
        return votes[claimId][verifier].effectiveStake;
    }

    function getVerificationSupport(uint256 claimId, address verifier) external view returns (bool) {
        return votes[claimId][verifier].support;
    }

    function getClaimVerificationWindowEnd(uint256 claimId) external view returns (uint256) {
        return claims[claimId].verificationWindowEnd;
    }

    function getClaimSubmitter(uint256 claimId) external view returns (address) {
        return claims[claimId].submitter;
    }

    /**
     * @notice Preview the effective stake for a user
     */
    function previewEffectiveStake(
        address user,
        uint256 stakeAmount
    ) external view returns (uint256 effectiveStake, uint256 reputationScore) {
        reputationScore = _getReputationScore(user);
        effectiveStake = _calculateEffectiveStake(stakeAmount, reputationScore);
    }

    /**
     * @notice Preview the effective stake for a user with current timestamp (for staleness tracking)
     * @param user The user address
     * @param stakeAmount The stake amount to preview
     * @return effectiveStake The calculated effective stake
     * @return reputationScore The current reputation score
     * @return timestamp The block timestamp of this preview (for staleness validation)
     */
    function previewEffectiveStakeWithTimestamp(
        address user,
        uint256 stakeAmount
    ) external view returns (uint256 effectiveStake, uint256 reputationScore, uint256 timestamp) {
        reputationScore = _getReputationScore(user);
        effectiveStake = _calculateEffectiveStake(stakeAmount, reputationScore);
        timestamp = block.timestamp;
    }

    /**
     * @notice Get the last recorded reputation snapshot for a user
     * @param user The user address
     * @return snapshot The reputation snapshot (score and timestamp)
     */
    function getLastReputationSnapshot(address user) external view returns (ReputationSnapshot memory snapshot) {
        return reputationSnapshots[user];
    }

    /**
     * @notice Check if a user's reputation has changed since their last preview
     * @param user The user address
     * @param previewReputation The reputation at preview time
     * @return hasChanged True if reputation changed more than the staleness threshold
     * @return currentReputation The current reputation score
     * @return timeSincePreview Time elapsed since the preview was made
     */
    function checkReputationStaleness(
        address user,
        uint256 previewReputation
    ) external view returns (bool hasChanged, uint256 currentReputation, uint256 timeSincePreview) {
        ReputationSnapshot memory snapshot = reputationSnapshots[user];
        currentReputation = _getReputationScore(user);
        timeSincePreview = block.timestamp - snapshot.timestamp;
        
        // Consider stale if reputation changed significantly or too much time has passed
        hasChanged = (currentReputation != previewReputation) || (timeSincePreview > MAX_REPUTATION_STALENESS);
    }

    /**
     * @notice Expose historical verification query for inspecting reputation, timestamp, epoch, and aggregation contribution (SC-013)
     * @param claimId The ID of the claim
     * @param verifier The verifier address
     * @return reputationUsed The reputation score captured at vote time
     * @return timestamp The timestamp when the vote/snapshot was recorded
     * @return epoch The epoch when the vote/snapshot was recorded
     * @return aggregationContribution The effective weighted stake contributed during vote aggregation
     */
    function getHistoricalVerification(
        uint256 claimId,
        address verifier
    ) external view returns (
        uint256 reputationUsed,
        uint256 timestamp,
        uint256 epoch,
        uint256 aggregationContribution
    ) {
        Vote storage v = votes[claimId][verifier];
        require(v.voted, "No vote cast");
        return (v.reputationScore, v.snapshotTimestamp, v.snapshotEpoch, v.effectiveStake);
    }

    /**
     * @notice Get structured Verification data for a claim and verifier (SC-013)
     * @param claimId The ID of the claim
     * @param verifier The verifier address
     * @return verification Struct containing full immutable verification snapshot details
     */
    function getVerification(
        uint256 claimId,
        address verifier
    ) external view returns (Verification memory verification) {
        Vote storage v = votes[claimId][verifier];
        require(v.voted, "No vote cast");
        return Verification({
            verifier: verifier,
            reputationSnapshot: v.reputationScore,
            snapshotTimestamp: v.snapshotTimestamp,
            snapshotEpoch: v.snapshotEpoch,
            snapshotRoot: v.snapshotRoot,
            effectiveStake: v.effectiveStake,
            stakeAmount: v.stakeAmount,
            support: v.support
        });
    }

    /**
     * @notice Get verification snapshot details for future Merkle proof compatibility (SC-013)
     * @param claimId The ID of the claim
     * @param verifier The verifier address
     * @return reputationSnapshot Reputation score recorded at vote time
     * @return snapshotTimestamp Timestamp recorded at vote time
     * @return snapshotEpoch Epoch recorded at vote time
     * @return snapshotRoot Merkle root (reserved for future proof verification)
     */
    function getVerificationSnapshot(
        uint256 claimId,
        address verifier
    ) external view returns (
        uint256 reputationSnapshot,
        uint256 snapshotTimestamp,
        uint256 snapshotEpoch,
        bytes32 snapshotRoot
    ) {
        Vote storage v = votes[claimId][verifier];
        require(v.voted, "No vote cast");
        return (v.reputationScore, v.snapshotTimestamp, v.snapshotEpoch, v.snapshotRoot);
    }

    // ============ Admin & Pauser Functions ============

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

    /**
     * @notice Safely migrates the primary payment bounty token
     * @param _newBountyToken The address of the new ERC20 token
     */
    function updateBountyToken(address _newBountyToken) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized");
        require(_newBountyToken != address(0), "Invalid token address");
        require(_newBountyToken != address(bountyToken), "Token already active");

        bountyToken = IERC20(_newBountyToken);
    }
}
