export interface PredictionEvent {
  id: string;
  marketId: string;
  status: number;
  eventType: number;
  description: string;
  outcomeLabels: string[];
  bettingStartTime: number;
  bettingEndTime: number;
  oracleFeedId: string;
  targetPrice: string;
  totalPool: number;
}

export interface PythPriceUpdateData {
  id: string;
  fetchedAt: number;
  priceFeedUpdateData: Buffer[];
}

export interface ResolutionTask {
  eventId: string;
  feedId: string;
  targetPrice: string;
  priority: number;
  createdAt: number;
}

export interface ResolutionResult {
  eventId: string;
  success: boolean;
  txDigest?: string;
  winningOutcome?: number;
  oraclePrice?: string;
  error?: string;
  gasUsed?: number;
  timestamp: number;
}

export enum EventStatus {
  CREATED = 0,
  OPEN = 1,
  LOCKED = 2,
  RESOLVED = 3,
  CANCELLED = 4,
}

export enum EventType {
  CRYPTO = 0,
  MANUAL = 1,
}

export const FEED_ID_TO_SYMBOL: Record<string, string> = {
  // SUI/USD (Pyth Sui testnet)
  '0x50c67b3f0a9bf5f93d10887c5f60ca6f50d46e26b8e1728bd7708a9bf0f6f7d0': 'SUI/USD',
};
