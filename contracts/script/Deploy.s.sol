// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {AccessController} from "../src/governance/AccessController.sol";
import {Treasury} from "../src/governance/Treasury.sol";
import {CreditIdentity} from "../src/identity/CreditIdentity.sol";
import {ScoreRegistry} from "../src/identity/ScoreRegistry.sol";
import {ScoringOracle} from "../src/scoring/ScoringOracle.sol";
import {ZKAttestationVerifier} from "../src/verification/ZKAttestationVerifier.sol";
import {DataOracleAdapter} from "../src/verification/DataOracleAdapter.sol";
import {AgentRegistry} from "../src/agents/AgentRegistry.sol";
import {X402PaymentRouter} from "../src/agents/X402PaymentRouter.sol";
import {RepaymentGraduation} from "../src/lending/RepaymentGraduation.sol";
import {SocialAttestation} from "../src/social/SocialAttestation.sol";
import {InterestRateModel} from "../src/lending/InterestRateModel.sol";
import {CreditLimitEngine} from "../src/lending/CreditLimitEngine.sol";
import {LendingPool} from "../src/lending/LendingPool.sol";
import {LoanManager} from "../src/lending/LoanManager.sol";
import {InsuranceFund} from "../src/risk/InsuranceFund.sol";
import {CreditSlasher} from "../src/risk/CreditSlasher.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

import {Roles} from "../src/libraries/Roles.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeployCreditGraph
/// @notice Deploys the full CreditGraph protocol to Arbitrum (One or Sepolia),
///         wires every post-deploy setter, and grants all required roles.
///
/// @dev Usage:
///   forge script script/Deploy.s.sol:DeployCreditGraph \
///     --rpc-url $ARB_SEPOLIA_RPC --broadcast --verify
///
/// Environment:
///   PRIVATE_KEY     deployer key (becomes admin/multisig stand-in)
///   USDC            existing USDC address; if unset, a MockUSDC is deployed
///   OPERATIONS      ops multisig for Treasury (defaults to deployer)
///   AGENT_REWARDS   agent reward pool (defaults to deployer)
contract DeployCreditGraph is Script {
    // ---- deployed addresses (populated during run) ----
    AccessController public access;
    MockUSDC public mockUsdc;
    address public usdc;

    CreditIdentity public identity;
    ScoreRegistry public scoreRegistry;
    AgentRegistry public agentRegistry;
    ScoringOracle public scoringOracle;
    ZKAttestationVerifier public zkVerifier;
    DataOracleAdapter public dataOracle;
    X402PaymentRouter public x402;

    RepaymentGraduation public graduation;
    SocialAttestation public social;
    InterestRateModel public rateModel;
    CreditLimitEngine public limitEngine;
    LendingPool public pool;
    LoanManager public loanManager;

    InsuranceFund public insuranceFund;
    CreditSlasher public slasher;
    Treasury public treasury;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address operations = vm.envOr("OPERATIONS", deployer);
        address agentRewards = vm.envOr("AGENT_REWARDS", deployer);

        vm.startBroadcast(pk);

        // ---- 0. USDC ----
        usdc = vm.envOr("USDC", address(0));
        if (usdc == address(0)) {
            mockUsdc = new MockUSDC();
            usdc = address(mockUsdc);
            console2.log("Deployed MockUSDC at", usdc);
        }

        // ---- 1. Access + identity + score ----
        access = new AccessController(deployer);
        identity = new CreditIdentity(address(access));
        scoreRegistry = new ScoreRegistry(address(access), address(identity), 90 days);

        // ---- 2. Agents ----
        agentRegistry = new AgentRegistry(address(access), usdc, 7 days);
        x402 = new X402PaymentRouter(address(access), usdc);

        // ---- 3. Scoring oracle (2-of-3 quorum, 1-day challenge) ----
        scoringOracle =
            new ScoringOracle(address(access), address(scoreRegistry), address(agentRegistry), 2, 1 days);

        // ---- 4. Verification ----
        zkVerifier = new ZKAttestationVerifier(address(access), address(identity));
        dataOracle = new DataOracleAdapter(address(access), 1 days);

        // ---- 5. Lending support ----
        graduation = new RepaymentGraduation(address(access));
        social = new SocialAttestation(address(access), usdc, address(identity), address(graduation));
        rateModel = new InterestRateModel(address(access));
        limitEngine = new CreditLimitEngine(
            address(access), address(scoreRegistry), address(graduation), address(social)
        );

        // ---- 6. Pool + risk ----
        pool = new LendingPool(address(access), IERC20(usdc), "CreditGraph USDC", "cgUSDC");
        insuranceFund = new InsuranceFund(address(access), usdc);
        slasher = new CreditSlasher(
            address(access), address(scoreRegistry), address(social), address(insuranceFund)
        );

        // ---- 7. LoanManager (depends on most of the above) ----
        loanManager = new LoanManager(
            address(access),
            usdc,
            address(identity),
            address(scoreRegistry),
            address(pool),
            address(limitEngine),
            address(rateModel),
            address(graduation)
        );

        // ---- 8. Treasury ----
        treasury =
            new Treasury(address(access), usdc, address(insuranceFund), operations, agentRewards);

        // ============================================================
        // POST-DEPLOY WIRING (setters that break circular dependencies)
        // ============================================================
        limitEngine.setLoanManager(address(loanManager));
        loanManager.setSlasher(address(slasher));
        slasher.setLoanManager(address(loanManager));
        social.setInsuranceFund(address(insuranceFund));
        insuranceFund.setCoverageRecipient(address(pool));

        // ============================================================
        // ROLE GRANTS
        // ============================================================
        bytes32[] memory roles = new bytes32[](6);
        address[] memory accts = new address[](6);

        // ScoringOracle writes scores.
        roles[0] = Roles.SCORE_UPDATER_ROLE;
        accts[0] = address(scoringOracle);
        // CreditSlasher reduces scores + slashes attestations.
        roles[1] = Roles.SLASHER_ROLE;
        accts[1] = address(slasher);
        // CreditSlasher spends the InsuranceFund.
        roles[2] = Roles.INSURANCE_SPENDER_ROLE;
        accts[2] = address(slasher);
        // LoanManager draws/returns pool funds + records graduation.
        roles[3] = Roles.POOL_MANAGER_ROLE;
        accts[3] = address(loanManager);
        // Deployer can mint identities (onboarding backend stand-in).
        roles[4] = Roles.MINTER_ROLE;
        accts[4] = deployer;
        // Deployer is a config admin already via constructor; also give the
        // Pool Manager agent slot to deployer for demo (data oracle feeds).
        roles[5] = Roles.CONFIG_ROLE;
        accts[5] = deployer;

        access.grantRoles(roles, accts);

        // Minimum agent stakes (USDC, 6 decimals): underwriters stake $100.
        agentRegistry.setMinStake(DataTypes.AgentRole.Underwriter, 100e6);
        agentRegistry.setMinStake(DataTypes.AgentRole.DataCollector, 50e6);
        agentRegistry.setMinStake(DataTypes.AgentRole.PoolManager, 100e6);
        agentRegistry.setMinStake(DataTypes.AgentRole.Recovery, 25e6);

        vm.stopBroadcast();

        _logDeployment();
    }

    function _logDeployment() internal view {
        console2.log("=== CreditGraph deployment ===");
        console2.log("USDC                ", usdc);
        console2.log("AccessController    ", address(access));
        console2.log("CreditIdentity      ", address(identity));
        console2.log("ScoreRegistry       ", address(scoreRegistry));
        console2.log("ScoringOracle       ", address(scoringOracle));
        console2.log("ZKAttestationVerifier", address(zkVerifier));
        console2.log("DataOracleAdapter   ", address(dataOracle));
        console2.log("AgentRegistry       ", address(agentRegistry));
        console2.log("X402PaymentRouter   ", address(x402));
        console2.log("RepaymentGraduation ", address(graduation));
        console2.log("SocialAttestation   ", address(social));
        console2.log("InterestRateModel   ", address(rateModel));
        console2.log("CreditLimitEngine   ", address(limitEngine));
        console2.log("LendingPool         ", address(pool));
        console2.log("LoanManager         ", address(loanManager));
        console2.log("InsuranceFund       ", address(insuranceFund));
        console2.log("CreditSlasher       ", address(slasher));
        console2.log("Treasury            ", address(treasury));
    }
}
