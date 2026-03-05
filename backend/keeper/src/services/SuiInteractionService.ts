import { Transaction } from '@mysten/sui/transactions';
import { SuiClient } from '@mysten/sui/client';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { decodeSuiPrivateKey } from '@mysten/sui/cryptography';
import { SuiPythClient } from '@pythnetwork/pyth-sui-js';
import { config, createSuiClient } from '../config';
import logger from '../utils/logger';
import { gasUsedHistogram, resolutionDurationHistogram } from '../utils/metrics';
import { PythPriceUpdateData, ResolutionResult, PredictionEvent } from '../types';

export class SuiInteractionService {
  private client: SuiClient;
  private keypair: Ed25519Keypair;
  private pythClient: SuiPythClient;

  constructor() {
    this.client = createSuiClient();
    const { secretKey } = decodeSuiPrivateKey(config.oraclePrivateKey);
    this.keypair = Ed25519Keypair.fromSecretKey(secretKey);
    this.pythClient = new SuiPythClient(
      this.client,
      config.pythStateId,
      config.wormholeStateId
    );

    logger.info('SuiInteractionService initialized', {
      network: config.suiNetwork,
      oracleAddress: config.oracleAddress,
    });
  }

  async buildResolutionTransaction(
    eventId: string,
    coinType: string,
    pythPriceData: PythPriceUpdateData
  ): Promise<Transaction> {
    const tx = new Transaction();
    tx.setGasBudget(config.gasBudget);

    // Update Pyth feed first and obtain the fresh PriceInfoObject ID.
    const priceInfoObjectIds = await this.pythClient.updatePriceFeeds(
      tx,
      pythPriceData.priceFeedUpdateData,
      [pythPriceData.id]
    );
    const [priceInfoObjectId] = priceInfoObjectIds;

    tx.moveCall({
      target: `${config.packageId}::blink_event::resolve_crypto_event`,
      typeArguments: [coinType],
      arguments: [
        tx.object(eventId),
        tx.object(config.marketId),
        tx.object(config.pythStateId),
        tx.object(priceInfoObjectId),
        tx.object('0x6'),
      ],
    });

    return tx;
  }

  async executeResolution(
    eventId: string,
    coinType: string,
    pythPriceData: PythPriceUpdateData
  ): Promise<ResolutionResult> {
    const end = resolutionDurationHistogram.startTimer();

    try {
      const tx = await this.buildResolutionTransaction(eventId, coinType, pythPriceData);
      const result = await this.client.signAndExecuteTransaction({
        signer: this.keypair,
        transaction: tx,
        options: {
          showEffects: true,
          showEvents: true,
          showBalanceChanges: true,
        },
      });

      end();

      if (result.effects?.status?.status !== 'success') {
        return {
          eventId,
          success: false,
          txDigest: result.digest,
          error: result.effects?.status?.error || 'Unknown error',
          timestamp: Date.now(),
        };
      }

      const gasUsed = Number(result.effects?.gasUsed?.computationCost || 0);
      gasUsedHistogram.observe(gasUsed);

      const resolvedEvent = result.events?.find((e) => e.type.includes('EventResolved'));
      let winningOutcome: number | undefined;
      let oraclePrice: string | undefined;
      if (resolvedEvent?.parsedJson) {
        const parsed = resolvedEvent.parsedJson as any;
        winningOutcome = parsed.winning_outcome;
        oraclePrice = parsed.oracle_price;
      }

      return {
        eventId,
        success: true,
        txDigest: result.digest,
        winningOutcome,
        oraclePrice,
        gasUsed,
        timestamp: Date.now(),
      };
    } catch (error: any) {
      end();
      logger.error('Failed to execute resolution transaction', {
        eventId,
        error: error.message,
      });

      return {
        eventId,
        success: false,
        error: error.message,
        timestamp: Date.now(),
      };
    }
  }

  async queryPendingEvents(): Promise<PredictionEvent[]> {
    try {
      const currentTime = Date.now();
      const response = await this.client.queryEvents({
        query: { MoveEventType: `${config.packageId}::blink_event::EventCreated` },
        limit: 100,
      });

      const pendingEvents: PredictionEvent[] = [];
      for (const createdEvent of response.data) {
        const created = createdEvent.parsedJson as any;
        if (!created?.event_id || created.event_type !== 0) continue;

        const eventDetails = await this.getEventDetails(created.event_id);
        if (
          eventDetails &&
          eventDetails.eventType === 0 &&
          eventDetails.status === 1 &&
          eventDetails.bettingEndTime <= currentTime
        ) {
          pendingEvents.push(eventDetails);
        }
      }

      return pendingEvents;
    } catch (error: any) {
      logger.error('Failed to query pending events', { error: error.message });
      return [];
    }
  }

  async getEventDetails(eventId: string): Promise<PredictionEvent | null> {
    try {
      const response = await this.client.getObject({
        id: eventId,
        options: { showContent: true },
      });

      const content = response.data?.content as any;
      if (!content?.fields) return null;
      const fields = content.fields;

      return {
        id: eventId,
        marketId: fields.market_id,
        status: Number(fields.status),
        eventType: Number(fields.event_type),
        description: fields.description,
        outcomeLabels: fields.outcome_labels,
        bettingStartTime: parseInt(fields.betting_start_time, 10),
        bettingEndTime: parseInt(fields.betting_end_time, 10),
        oracleFeedId: normalizeFeedId(fields.oracle_feed_id),
        targetPrice: fields.target_price,
        totalPool: parseInt(fields.total_pool || '0', 10),
      };
    } catch (error: any) {
      logger.error('Failed to get event details', { eventId, error: error.message });
      return null;
    }
  }
}

function normalizeFeedId(rawFeedId: unknown): string {
  if (typeof rawFeedId === 'string') {
    return rawFeedId.startsWith('0x') ? rawFeedId.toLowerCase() : `0x${rawFeedId.toLowerCase()}`;
  }

  if (Array.isArray(rawFeedId)) {
    const hex = rawFeedId
      .map((b) => Number(b).toString(16).padStart(2, '0'))
      .join('');
    return `0x${hex}`;
  }

  return '';
}
