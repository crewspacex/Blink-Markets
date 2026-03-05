import { SuiPriceServiceConnection } from '@pythnetwork/pyth-sui-js';
import { config } from '../config';
import logger from '../utils/logger';
import { oracleApiCallsTotal, oracleApiDurationHistogram } from '../utils/metrics';
import { PythPriceUpdateData } from '../types';

export class PythOracleService {
  private connection: SuiPriceServiceConnection;

  constructor() {
    this.connection = new SuiPriceServiceConnection(config.pythHermesUrl, {
      timeout: config.oracleTimeoutMs,
    });

    logger.info('PythOracleService initialized', {
      hermesUrl: config.pythHermesUrl,
    });
  }

  async getLatestPrice(feedId: string): Promise<PythPriceUpdateData | null> {
    const end = oracleApiDurationHistogram.startTimer();

    try {
      logger.debug('Fetching update data from Pyth Hermes', { feedId });
      const updateData = await this.connection.getPriceFeedsUpdateData([feedId]);
      oracleApiCallsTotal.inc({ status: 'success' });
      end();

      if (!updateData || updateData.length === 0) {
        logger.warn('No update data returned by Hermes', { feedId });
        return null;
      }

      return {
        id: feedId,
        fetchedAt: Date.now(),
        priceFeedUpdateData: updateData,
      };
    } catch (error: any) {
      end();
      oracleApiCallsTotal.inc({ status: 'error' });
      logger.error('Failed to fetch update data from Hermes', {
        feedId,
        error: error.message,
      });
      return null;
    }
  }

  async getBatchPrices(feedIds: string[]): Promise<Map<string, PythPriceUpdateData>> {
    const end = oracleApiDurationHistogram.startTimer();
    const results = new Map<string, PythPriceUpdateData>();

    try {
      const uniqueFeedIds = [...new Set(feedIds)];
      logger.debug('Fetching batch update data from Hermes', {
        count: uniqueFeedIds.length,
      });

      for (const feedId of uniqueFeedIds) {
        const updateData = await this.connection.getPriceFeedsUpdateData([feedId]);
        if (updateData && updateData.length > 0) {
          results.set(feedId, {
            id: feedId,
            fetchedAt: Date.now(),
            priceFeedUpdateData: updateData,
          });
        }
      }

      oracleApiCallsTotal.inc({ status: 'success' });
      end();
      return results;
    } catch (error: any) {
      end();
      oracleApiCallsTotal.inc({ status: 'error' });
      logger.error('Failed to fetch batch update data from Hermes', {
        feedIds,
        error: error.message,
      });
      return results;
    }
  }

  async fetchWithRetry(
    feedId: string,
    maxRetries: number = config.maxRetries
  ): Promise<PythPriceUpdateData | null> {
    let lastError: Error | null = null;

    for (let attempt = 0; attempt < maxRetries; attempt++) {
      try {
        const result = await this.getLatestPrice(feedId);
        if (result) {
          return result;
        }
      } catch (error: any) {
        lastError = error;
      }

      if (attempt < maxRetries - 1) {
        const delay = config.retryDelayMs * Math.pow(2, attempt);
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }

    logger.error('All retry attempts failed for Hermes call', {
      feedId,
      maxRetries,
      lastError: lastError?.message,
    });
    return null;
  }

  isValidFeedId(feedId: string): boolean {
    const cleanFeedId = feedId.startsWith('0x') ? feedId.slice(2) : feedId;
    return /^[0-9a-fA-F]{64}$/.test(cleanFeedId);
  }
}
