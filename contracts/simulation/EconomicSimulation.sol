// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./IEconomicSimulation.sol";
import "../IReputationOracle.sol";

/**
 * @title EconomicSimulation
 * @notice Protocol Economic Simulation & Stress Testing Framework (SC-032)
 * @dev Enables deterministic simulation of protocol economics under a wide range
 *      of scenarios without affecting live protocol state.
 *
 *      The framework is intended for governance decision-making, audit validation,
 *      and continuous economic verification. Simulation results are advisory and
 *      must never directly execute protocol changes.
 *
 * Key design properties:
 * - Completely isolated from production protocol logic
 * - Deterministic and reproducible across runs
 * - Reusable by governance tooling, researchers, and auditors
 * - Machine-readable reports with generated warnings and recommendations
 */
contract EconomicSimulation is
    IEconomicSimulation,
    AccessControl,
    ReentrancyGuard,
    Pausable
{
    // ============ Roles ============

    bytes32 public constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");
    bytes32 public constant SIMULATOR_ROLE   = keccak256("SIMULATOR_ROLE");
    bytes32 public constant PAUSER_ROLE      = keccak256("PAUSER_ROLE");

    // ============ Constants ============

    /// @notice Basis points denominator (100%)
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_SUSTAINABLE_INFLATION_BPS = 500;   // 5% annual
    uint256 public constant MIN_SUSTAINABLE_TREASURY_BPS = 2000;  // 20% of initial
    uint256 public constant MIN_VERIFIER_PROFITABILITY = 1e17;     // 0.1 token
    uint256 public constant MAX_RESERVE_UTILISATION_BPS = 8000;    // 80%

    // ============ State ============

    /// @notice Auto-incrementing simulation counter
    uint256 private _simulationCounter;

    /// @notice simulationId => SimulationReport
    mapping(bytes32 => SimulationReport) private _reports;

    /// @notice Ordered list of simulation IDs
    bytes32[] private _simulationIds;

    /// @notice Economic thresholds that trigger warnings
    mapping(bytes32 => uint256) public economicThresholds;

    // ============ Events ============

    event ThresholdUpdated(bytes32 indexed metricId, uint256 oldValue, uint256 newValue);
    event SimulationLimitExceeded(bytes32 indexed simulationId, string reason);

    // ============ Errors ============

    error SimulationNotFound(bytes32 simulationId);
    error InvalidConfig();
    error ZeroAddress();
    error InvalidDuration();

    // ============ Constructor ============

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE,         initialAdmin);
        _grantRole(SIMULATOR_ROLE,     initialAdmin);
        _grantRole(PAUSER_ROLE,        initialAdmin);

        _setRoleAdmin(SIMULATOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE,    ADMIN_ROLE);

        // Set default economic thresholds
        economicThresholds[keccak256("INFLATION_RATE")]        = MAX_SUSTAINABLE_INFLATION_BPS;
        economicThresholds[keccak256("TREASURY_SOLVENCY")]     = 1e22; // Minimum treasury
        economicThresholds[keccak256("RESERVE_UTILISATION")]   = MAX_RESERVE_UTILISATION_BPS;
        economicThresholds[keccak256("VERIFIER_PROFITABILITY")] = MIN_VERIFIER_PROFITABILITY;
    }

    // ============ Monte Carlo Support (Future) ============

    /// @dev Design stub for future Monte Carlo probabilistic simulations.
    ///      NEXT_VERSION: Implement simulateMonteCarlo() with random participation
    ///      sampling, variable claim volume distributions, and stochastic economic
    ///      state transitions.
    ///
    /// struct RandomConfig {
    ///     uint256 seed;
    ///     uint256 participationStdDev;  // Standard deviation for participation sampling
    ///     uint256 claimVolumeVariance;  // Max variance in daily claim volume (BPS)
    ///     uint256 adoptionCurve;        // Adoption curve parameter for growth modelling
    ///     uint256 iterations;           // Number of Monte Carlo iterations
    /// }
    ///
    /// function simulateMonteCarlo(
    ///     SimulationConfig memory config,
    ///     RandomConfig memory randomConfig
    /// ) external returns (MonteCarloReport memory report);

    // ============ Core Simulation ============

    /**
     * @inheritdoc IEconomicSimulation
     */
    function simulate(
        SimulationConfig calldata config
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(SIMULATOR_ROLE)
        returns (SimulationReport memory report)
    {
        if (config.durationDays == 0) revert InvalidDuration();

        bytes32 simulationId = _generateSimulationId(config);
        EconomicMetrics memory metrics = _runSimulation(config);
        (string[] memory warnings, string[] memory recommendations) = _analyzeResults(config, metrics);

        report = SimulationReport({
            simulationId:    simulationId,
            scenario:        config.scenario,
            config:          config,
            metrics:         metrics,
            warnings:        warnings,
            recommendations: recommendations,
            timestamp:       block.timestamp,
            valid:           warnings.length == 0 || _isConfigValid(config)
        });

        _reports[simulationId] = report;
        _simulationIds.push(simulationId);
        _simulationCounter++;

        emit SimulationExecuted(simulationId, config.scenario);
        emit SimulationCompleted(simulationId);

        // Emit threshold warnings
        if (metrics.inflationRate > economicThresholds[keccak256("INFLATION_RATE")]) {
            emit EconomicThresholdExceeded(keccak256("INFLATION_RATE"), metrics.inflationRate);
        }
        if (metrics.reserveUtilisation > economicThresholds[keccak256("RESERVE_UTILISATION")]) {
            emit EconomicThresholdExceeded(keccak256("RESERVE_UTILISATION"), metrics.reserveUtilisation);
        }

        return report;
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function previewSimulation(
        SimulationConfig calldata config
    ) external view returns (EconomicMetrics memory metrics) {
        return _runSimulation(config);
    }

    // ============ Economic Simulation Engine ============

    /**
     * @dev Run a deterministic economic simulation given the config.
     *      This is a pure simulation — no state mutations occur outside
     *      the memory-based computation.
     */
    function _runSimulation(
        SimulationConfig memory config
    ) internal pure returns (EconomicMetrics memory metrics) {
        // ── Apply scenario-based modifiers ─────────────────────────────
        (uint256 verifierBonus, uint256 claimMultiplier, uint256 revenueMultiplier) =
            _getScenarioModifiers(config.scenario);

        // ── Base variables ─────────────────────────────────────────────
        uint256 treasury          = config.initialTreasury;
        uint256 verifiers         = config.initialVerifiers;
        uint256 stakers           = config.initialStakers;
        uint256 dailyClaims       = config.dailyClaimVolume * claimMultiplier / BPS;
        uint256 durationDays      = config.durationDays;

        GovernanceParams memory gp = config.govParams;

        // ── Simulate day by day ────────────────────────────────────────
        uint256 totalRewards;
        uint256 totalRevenue;
        uint256 totalSettlements;

        for (uint256 day = 0; day < durationDays; day++) {
            // ── Verifier participation ─────────────────────────────────
            uint256 activeVerifiers = verifiers * _getParticipationRate(config.scenario, day) / BPS;

            // ── Daily claims and settlement ────────────────────────────
            uint256 settledToday = dailyClaims;
            totalSettlements += settledToday;

            // ── Staking dynamics ───────────────────────────────────────
            uint256 totalStaked = stakers * gp.minStakeAmount * (1e18 + verifierBonus) / 1e18;

            // ── Settlement outcomes ────────────────────────────────────
            // Simulate round-robin: some correct, some incorrect
            uint256 correctVotes = settledToday * 70 / 100; // 70% correct baseline
            uint256 incorrectVotes = settledToday - correctVotes;

            // ── Reward emissions ───────────────────────────────────────
            uint256 dailyReward = _calculateDailyRewards(
                activeVerifiers,
                totalStaked,
                gp.rewardPercent,
                gp.slashPercent,
                settledToday
            );
            totalRewards += dailyReward;

            // ── Protocol revenue (fees + slashing redistribution) ──────
            uint256 dailyRevenue = _calculateDailyRevenue(
                settledToday,
                totalStaked,
                gp.slashPercent,
                revenueMultiplier
            );
            totalRevenue += dailyRevenue;

            // ── Treasury update ────────────────────────────────────────
            // Treasury earns revenue (fees, slashing) and spends rewards
            treasury = treasury + dailyRevenue - dailyReward;

            // Prevent underflow
            if (treasury > type(uint256).max / 2) {
                treasury = 0;
            }

            // ── Verifier / staker growth ───────────────────────────────
            if (treasury > config.initialTreasury / 2) {
                verifiers = verifiers + (verifiers * 5 / BPS); // 0.05% daily growth
                stakers   = stakers + (stakers * 3 / BPS);     // 0.03% daily growth
            }
        }

        // ── Compute final metrics ──────────────────────────────────────
        metrics.treasurySolvency       = treasury;

        uint256 totalStakedEnd = stakers * gp.minStakeAmount;

        metrics.totalRewardEmissions   = totalRewards;
        metrics.protocolRevenue        = totalRevenue;

        // Verifier profitability: average reward per verifier over the period
        uint256 avgVerifiers = (config.initialVerifiers + verifiers) / 2;
        metrics.verifierProfitability = avgVerifiers > 0
            ? totalRewards / avgVerifiers
            : 0;

        metrics.averageSettlementCost  = totalSettlements > 0
            ? totalRewards / totalSettlements
            : 0;

        // Inflation rate: rewards as percentage of total staked (annualised)
        uint256 annualisedRewards = totalRewards * 365 days / (durationDays * 1 days);
        uint256 economicBase = config.initialTreasury > 0 ? config.initialTreasury : 1e18;
        metrics.inflationRate = (annualisedRewards * BPS) / economicBase;

        // Reserve utilisation: portion of initial treasury used
        metrics.reserveUtilisation = config.initialTreasury > 0
            ? ((config.initialTreasury - treasury) * BPS) / config.initialTreasury
            : 0;

        // Sustainability index: composite score (0-10000, higher = better)
        metrics.sustainabilityIndex = _calculateSustainabilityIndex(metrics);
    }

    // ============ Scenario Modifiers ============

    function _getScenarioModifiers(Scenario scenario)
        internal pure returns (uint256 verifierBonus, uint256 claimMultiplier, uint256 revenueMultiplier)
    {
        if (scenario == Scenario.NORMAL_GROWTH) {
            return (0, BPS, BPS); // 1x baseline
        } else if (scenario == Scenario.HIGH_GROWTH) {
            return (5e17, 3 * BPS, 2 * BPS); // +50% verifier bonus, 3x claims, 2x revenue
        } else if (scenario == Scenario.LOW_PARTICIPATION) {
            return (0, BPS / 3, BPS / 2); // 33% claims, 50% revenue
        } else if (scenario == Scenario.ADVERSARIAL_BEHAVIOUR) {
            return (0, BPS * 2, BPS / 3); // 2x claims (spam), 33% revenue
        } else if (scenario == Scenario.TREASURY_STRESS) {
            return (0, BPS, BPS / 4); // 25% revenue
        } else        if (scenario == Scenario.GOVERNANCE_CHANGE) {
            return (1e18, BPS * 2, BPS + (BPS / 2)); // +100% verifier bonus, 2x claims, 1.5x revenue
        }
        return (0, BPS, BPS);
    }

    /**
     * @dev Get participation rate that varies over time for some scenarios
     */
    function _getParticipationRate(Scenario scenario, uint256 day) internal pure returns (uint256) {
        if (scenario == Scenario.LOW_PARTICIPATION) {
            // Declining participation: starts at 80%, drops to 20%
            uint256 decay = day * 50; // 0.5% per day
            return decay > 8000 ? 2000 : 8000 - decay;
        }
        if (scenario == Scenario.ADVERSARIAL_BEHAVIOUR) {
            // Fluctuating participation due to attacks
            return day % 7 < 3 ? 4000 : 7000; // Periodic drops
        }
        // Stable participation (80-95%)
        return 8000 + (day % 1500);
    }

    // ============ Economic Calculators ============

    function _calculateDailyRewards(
        uint256 activeVerifiers,
        uint256 totalStaked,
        uint256 rewardPercent,
        uint256 slashPercent,
        uint256 settledToday
    ) internal pure returns (uint256) {
        if (totalStaked == 0) return 0;

        // Rewards are a fraction of slashed amounts from incorrect votes
        uint256 incorrectStake = totalStaked * 30 / 100; // Assume 30% incorrect by default
        uint256 slashedAmount   = (incorrectStake * slashPercent * settledToday) / (100 * 1000);
        uint256 rewardAmount    = (slashedAmount * rewardPercent) / 100;

        return rewardAmount;
    }

    function _calculateDailyRevenue(
        uint256 settledToday,
        uint256 totalStaked,
        uint256 slashPercent,
        uint256 revenueMultiplier
    ) internal pure returns (uint256) {
        // Revenue: protocol fees on slashed amounts + treasury yield
        if (totalStaked == 0) return 0;

        uint256 incorrectStake = totalStaked * 30 / 100;
        uint256 slashedAmount   = (incorrectStake * slashPercent * settledToday) / (100 * 1000);
        uint256 protocolFee     = (slashedAmount * 10) / 100; // 10% protocol fee on slashed
        uint256 baseRevenue     = protocolFee * revenueMultiplier / BPS;

        return baseRevenue;
    }

    // ============ Results Analysis ============

    function _analyzeResults(
        SimulationConfig memory config,
        EconomicMetrics memory metrics
    ) internal view returns (string[] memory warnings, string[] memory recommendations) {
        // We build warnings/recommendations dynamically
        // Each warning/recommendation is a machine-readable string

        uint256 warningCount = 0;
        uint256 recCount = 0;

        // Count potential warnings
        bool highInflation = metrics.inflationRate > MAX_SUSTAINABLE_INFLATION_BPS;
        bool lowTreasury   = metrics.treasurySolvency < config.initialTreasury * MIN_SUSTAINABLE_TREASURY_BPS / BPS;
        bool lowProfit     = metrics.verifierProfitability < MIN_VERIFIER_PROFITABILITY;
        bool highUtil      = metrics.reserveUtilisation > MAX_RESERVE_UTILISATION_BPS;
        bool badSustain    = metrics.sustainabilityIndex < 3000;

        if (highInflation) warningCount++;
        if (lowTreasury)   warningCount++;
        if (lowProfit)     warningCount++;
        if (highUtil)      warningCount++;
        if (badSustain)    warningCount++;

        if (highInflation) recCount++;
        if (lowTreasury)   recCount++;
        if (lowProfit)     recCount++;
        if (highUtil)      recCount++;
        if (badSustain)    recCount++;

        // General recommendation if under-sustainable
        if (metrics.sustainabilityIndex < 5000) recCount++;

        warnings        = new string[](warningCount);
        recommendations = new string[](recCount);

        uint256 wi = 0;
        uint256 ri = 0;

        if (highInflation) {
            warnings[wi++] = string(abi.encodePacked("HIGH_INFLATION:Rate=", _uintToString(metrics.inflationRate), "bps"));
            recommendations[ri++] = "Reduce reward percent or increase slash percent to curb inflation.";
        }
        if (lowTreasury) {
            warnings[wi++] = string(abi.encodePacked("LOW_TREASURY:Balance=", _uintToString(metrics.treasurySolvency)));
            recommendations[ri++] = "Increase protocol fees or reduce reward emissions to preserve treasury.";
        }
        if (lowProfit) {
            warnings[wi++] = string(abi.encodePacked("LOW_VERIFIER_PROFIT:Avg=", _uintToString(metrics.verifierProfitability)));
            recommendations[ri++] = "Increase reward incentives or adjust settlement threshold to attract verifiers.";
        }
        if (highUtil) {
            warnings[wi++] = string(abi.encodePacked("HIGH_RESERVE_UTILISATION:Util=", _uintToString(metrics.reserveUtilisation), "bps"));
            recommendations[ri++] = "Reduce treasury spending rate or increase revenue streams.";
        }
        if (badSustain) {
            warnings[wi++] = string(abi.encodePacked("LOW_SUSTAINABILITY:Index=", _uintToString(metrics.sustainabilityIndex)));
            recommendations[ri++] = "Review governance parameter configuration for long-term sustainability.";
        }
        if (metrics.sustainabilityIndex < 5000 && !badSustain) {
            recommendations[ri++] = "Consider adjusting economic parameters to improve protocol sustainability index.";
        }
    }

    // ============ Sustainability Index ============

    /**
     * @dev Calculate a composite sustainability index (0-10000).
     *      Higher is better. Considers treasury health, inflation,
     *      verifier profitability, and reserve utilisation.
     */
    function _calculateSustainabilityIndex(
        EconomicMetrics memory metrics
    ) internal pure returns (uint256) {
        // Score components (each 0-2500, summed to 0-10000)
        uint256 score;

        // Treasury health (0-2500)
        if (metrics.treasurySolvency >= 1e24) {
            score += 2500;
        } else if (metrics.treasurySolvency > 0) {
            score += uint256(2500 * metrics.treasurySolvency / 1e24);
        }

        // Inflation score: lower is better (0-2500)
        if (metrics.inflationRate <= 100) {
            score += 2500;
        } else if (metrics.inflationRate <= MAX_SUSTAINABLE_INFLATION_BPS) {
            score += uint256(2500 * (MAX_SUSTAINABLE_INFLATION_BPS - metrics.inflationRate) / MAX_SUSTAINABLE_INFLATION_BPS);
        }
        // else 0 for excessive inflation

        // Verifier profitability (0-2500)
        if (metrics.verifierProfitability >= 1e18) {
            score += 2500;
        } else if (metrics.verifierProfitability > 0) {
            score += uint256(2500 * metrics.verifierProfitability / 1e18);
        }

        // Reserve utilisation score: moderate is good (0-2500)
        if (metrics.reserveUtilisation <= MAX_RESERVE_UTILISATION_BPS) {
            score += uint256(2500 * (MAX_RESERVE_UTILISATION_BPS - metrics.reserveUtilisation) / MAX_RESERVE_UTILISATION_BPS);
        }
        // else 0 for over-utilisation

        return score;
    }

    // ============ Config Validation ============

    function _isConfigValid(SimulationConfig memory config) internal pure returns (bool) {
        if (config.durationDays == 0) return false;
        if (config.durationDays > 3650) return false; // Max 10 years
        if (config.govParams.rewardPercent == 0 || config.govParams.rewardPercent > 100) return false;
        if (config.govParams.slashPercent == 0 || config.govParams.slashPercent > 100) return false;
        if (config.govParams.minStakeAmount == 0) return false;
        if (config.govParams.settlementThresholdPercent == 0 || config.govParams.settlementThresholdPercent > 100) return false;
        if (config.govParams.verificationWindowDuration < 1 hours) return false;
        return true;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IEconomicSimulation
     */
    function getAvailableScenarios() external pure returns (Scenario[] memory) {
        Scenario[] memory scenarios = new Scenario[](6);
        scenarios[0] = Scenario.NORMAL_GROWTH;
        scenarios[1] = Scenario.HIGH_GROWTH;
        scenarios[2] = Scenario.LOW_PARTICIPATION;
        scenarios[3] = Scenario.ADVERSARIAL_BEHAVIOUR;
        scenarios[4] = Scenario.TREASURY_STRESS;
        scenarios[5] = Scenario.GOVERNANCE_CHANGE;
        return scenarios;
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function getScenarioName(Scenario scenario) external pure returns (string memory) {
        if (scenario == Scenario.NORMAL_GROWTH)         return "Normal Growth";
        if (scenario == Scenario.HIGH_GROWTH)            return "High Growth";
        if (scenario == Scenario.LOW_PARTICIPATION)      return "Low Participation";
        if (scenario == Scenario.ADVERSARIAL_BEHAVIOUR)  return "Adversarial Behaviour";
        if (scenario == Scenario.TREASURY_STRESS)        return "Treasury Stress";
        if (scenario == Scenario.GOVERNANCE_CHANGE)      return "Governance Change";
        return "Unknown";
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function getScenarioDescription(Scenario scenario) external pure returns (string memory) {
        if (scenario == Scenario.NORMAL_GROWTH) {
            return "Steady claim creation, stable verifier participation, sustainable treasury growth.";
        }
        if (scenario == Scenario.HIGH_GROWTH) {
            return "Rapid user onboarding, increased claim volume, increased reward distribution.";
        }
        if (scenario == Scenario.LOW_PARTICIPATION) {
            return "Declining verifier activity, reduced staking, slower settlements.";
        }
        if (scenario == Scenario.ADVERSARIAL_BEHAVIOUR) {
            return "Sybil attacks, spam claims, reward farming, coordinated collusion.";
        }
        if (scenario == Scenario.TREASURY_STRESS) {
            return "Reduced revenue, increased payouts, emergency expenditures.";
        }
        if (scenario == Scenario.GOVERNANCE_CHANGE) {
            return "Modified reward multipliers, staking requirement updates, fee adjustments, treasury allocation changes.";
        }
        return "";
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function getSimulation(bytes32 simulationId) external view returns (SimulationReport memory) {
        if (_reports[simulationId].timestamp == 0) revert SimulationNotFound(simulationId);
        return _reports[simulationId];
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function getSimulationCount() external view returns (uint256) {
        return _simulationCounter;
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function getSimulationsPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 total = _simulationIds.length;
        if (offset >= total) return new bytes32[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        ids = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = _simulationIds[i];
        }
    }

    /**
     * @inheritdoc IEconomicSimulation
     */
    function validateGovernanceParams(
        GovernanceParams calldata params
    ) external view returns (string[] memory warnings, bool safe) {
        uint256 count = 0;

        if (params.slashPercent == 0 || params.slashPercent > 50) count++;
        if (params.rewardPercent == 0 || params.rewardPercent > 100) count++;
        if (params.rewardPercent + params.slashPercent > 100) count++;
        if (params.minStakeAmount == 0) count++;
        if (params.settlementThresholdPercent == 0 || params.settlementThresholdPercent > 100) count++;
        if (params.rewardIncrement == 0) count++;
        if (params.penaltyAmount == 0) count++;
        if (params.maliciousMultiplier == 0) count++;
        if (params.verificationWindowDuration < 1 hours) count++;
        if (params.verificationWindowDuration > 30 days) count++;

        warnings = new string[](count);
        uint256 i = 0;

        if (params.slashPercent == 0 || params.slashPercent > 50) {
            warnings[i++] = "Slash percent must be between 1 and 50.";
        }
        if (params.rewardPercent == 0 || params.rewardPercent > 100) {
            warnings[i++] = "Reward percent must be between 1 and 100.";
        }
        if (params.rewardPercent + params.slashPercent > 100) {
            warnings[i++] = "Reward percent + slash percent exceeds 100%.";
        }
        if (params.minStakeAmount == 0) {
            warnings[i++] = "Min stake amount must be greater than 0.";
        }
        if (params.settlementThresholdPercent == 0 || params.settlementThresholdPercent > 100) {
            warnings[i++] = "Settlement threshold must be between 1 and 100.";
        }
        if (params.rewardIncrement == 0) {
            warnings[i++] = "Reward increment must be greater than 0.";
        }
        if (params.penaltyAmount == 0) {
            warnings[i++] = "Penalty amount must be greater than 0.";
        }
        if (params.maliciousMultiplier == 0) {
            warnings[i++] = "Malicious multiplier must be greater than 0.";
        }
        if (params.verificationWindowDuration < 1 hours) {
            warnings[i++] = "Verification window must be at least 1 hour.";
        }
        if (params.verificationWindowDuration > 30 days) {
            warnings[i++] = "Verification window must not exceed 30 days.";
        }

        safe = (warnings.length == 0);
    }

    // ============ Admin Functions ============

    /**
     * @inheritdoc IEconomicSimulation
     */
    function setEconomicThreshold(bytes32 metricId, uint256 threshold) external onlyRole(ADMIN_ROLE) {
        uint256 old = economicThresholds[metricId];
        economicThresholds[metricId] = threshold;
        emit ThresholdUpdated(metricId, old, threshold);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ============ Internal Helpers ============

    function _generateSimulationId(SimulationConfig memory config) internal view returns (bytes32) {
        return keccak256(abi.encode(
            config.scenario,
            config.durationDays,
            config.initialTreasury,
            config.initialVerifiers,
            config.initialStakers,
            config.dailyClaimVolume,
            config.govParams,
            block.timestamp,
            _simulationCounter
        ));
    }

    /**
     * @dev Convert a uint256 to a string (basic implementation)
     */
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
