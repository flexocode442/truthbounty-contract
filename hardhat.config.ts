import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-gas-reporter";
import "@nomicfoundation/hardhat-ignition-ethers";
import * as dotenv from "dotenv";
import "@openzeppelin/hardhat-upgrades";

dotenv.config();

const config: HardhatUserConfig = {
solidity: {
    version: "0.8.28",
    settings: {
      evmVersion: "cancun",
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    optimismSepolia: {
      url:
        process.env.OPTIMISM_SEPOLIA_RPC_URL || "https://sepolia.optimism.io",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 11155420,
      gas: "auto",
      gasPrice: process.env.OPTIMISM_SEPOLIA_GAS_PRICE
        ? parseInt(process.env.OPTIMISM_SEPOLIA_GAS_PRICE)
        : undefined,
    },
    optimismMainnet: {
      url:
        process.env.OPTIMISM_MAINNET_RPC_URL || "https://mainnet.optimism.io",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 10,
      gas: "auto",
      gasPrice: process.env.OPTIMISM_MAINNET_GAS_PRICE
        ? parseInt(process.env.OPTIMISM_MAINNET_GAS_PRICE)
        : undefined,
    },
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY || "",
      optimisticEthereum: process.env.OPTIMISM_ETHERSCAN_API_KEY || "",
      optimisticSepolia: process.env.OPTIMISM_ETHERSCAN_API_KEY || "",
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    outputFile: ".gas-reports.json",
    noColors: true,
    excludeContracts: [],
    // @ts-ignore
    snapshots: {
      outputFile: ".gas-snapshots.json",
    },
  },
};

export default config;
