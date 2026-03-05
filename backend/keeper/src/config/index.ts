import dotenv from 'dotenv';
import { SuiClient } from '@mysten/sui/client';

dotenv.config();

export interface Config {
  suiNetwork: string;
  suiRpcUrl: string;
  packageId: string;
  pythPackageId: string;
  pythStateId: string;
  wormholeStateId: string;
  marketId: string;
  oraclePrivateKey: string;
  oracleAddress: string;
  pythHermesUrl: string;
  pythFeedSuiUsd: string;
  redis: {
    host: string;
    port: number;
    password?: string;
    db: number;
  };
  pollingIntervalMs: number;
  batchWindowMs: number;
  maxBatchSize: number;
  resolutionLockTtlSec: number;
  gasBudget: number;
  maxGasPrice: number;
  prometheusPort: number;
  logLevel: string;
  maxRetries: number;
  retryDelayMs: number;
  oracleTimeoutMs: number;
}

function validateEnv(key: string): string {
  const value = process.env[key];
  if (!value) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
  return value;
}

function getEnv(key: string, defaultValue: string): string {
  return process.env[key] || defaultValue;
}

export const config: Config = {
  suiNetwork: getEnv('SUI_NETWORK', 'testnet'),
  suiRpcUrl: validateEnv('SUI_RPC_URL'),
  packageId: validateEnv('PACKAGE_ID'),
  pythPackageId: validateEnv('PYTH_PACKAGE_ID'),
  pythStateId: validateEnv('PYTH_STATE_ID'),
  wormholeStateId: validateEnv('WORMHOLE_STATE_ID'),
  marketId: validateEnv('MARKET_ID'),
  oraclePrivateKey: validateEnv('ORACLE_PRIVATE_KEY'),
  oracleAddress: validateEnv('ORACLE_ADDRESS'),
  pythHermesUrl: getEnv('PYTH_HERMES_URL', 'https://hermes.pyth.network'),
  pythFeedSuiUsd: validateEnv('PYTH_FEED_SUI_USD'),
  redis: {
    host: getEnv('REDIS_HOST', 'localhost'),
    port: parseInt(getEnv('REDIS_PORT', '6379'), 10),
    password: process.env.REDIS_PASSWORD,
    db: parseInt(getEnv('REDIS_DB', '0'), 10),
  },
  pollingIntervalMs: parseInt(getEnv('POLLING_INTERVAL_MS', '3000'), 10),
  batchWindowMs: parseInt(getEnv('BATCH_WINDOW_MS', '5000'), 10),
  maxBatchSize: parseInt(getEnv('MAX_BATCH_SIZE', '10'), 10),
  resolutionLockTtlSec: parseInt(getEnv('RESOLUTION_LOCK_TTL_SEC', '30'), 10),
  gasBudget: parseInt(getEnv('GAS_BUDGET', '100000000'), 10),
  maxGasPrice: parseInt(getEnv('MAX_GAS_PRICE', '1000'), 10),
  prometheusPort: parseInt(getEnv('PROMETHEUS_PORT', '9090'), 10),
  logLevel: getEnv('LOG_LEVEL', 'info'),
  maxRetries: parseInt(getEnv('MAX_RETRIES', '3'), 10),
  retryDelayMs: parseInt(getEnv('RETRY_DELAY_MS', '1000'), 10),
  oracleTimeoutMs: parseInt(getEnv('ORACLE_TIMEOUT_MS', '10000'), 10),
};

export function createSuiClient(): SuiClient {
  return new SuiClient({ url: config.suiRpcUrl });
}
