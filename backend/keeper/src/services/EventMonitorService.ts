import { SuiInteractionService } from './SuiInteractionService';
import { PythOracleService } from './PythOracleService';
import { ResolutionLockService } from './ResolutionLockService';
import { config } from '../config';
import logger from '../utils/logger';
import {
  pendingEventsGauge,
  eventsResolvedTotal,
  resolutionErrorsTotal,
} from '../utils/metrics';
import { PredictionEvent, ResolutionTask, FEED_ID_TO_SYMBOL } from '../types';

export class EventMonitorService {
  private suiService: SuiInteractionService;
  private pythService: PythOracleService;
  private lockService: ResolutionLockService;
  private isRunning = false;
  private pollingInterval: NodeJS.Timeout | null = null;
  private batchQueue: Map<string, ResolutionTask> = new Map();
  private lastBatchTime = Date.now();

  constructor(
    suiService: SuiInteractionService,
    pythService: PythOracleService,
    lockService: ResolutionLockService
  ) {
    this.suiService = suiService;
    this.pythService = pythService;
    this.lockService = lockService;
  }

  /**
   * Start monitoring and resolving events
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      logger.warn('EventMonitorService already running');
      return;
    }

    this.isRunning = true;
    logger.info('Starting EventMonitorService', {
      pollingIntervalMs: config.pollingIntervalMs,
      batchWindowMs: config.batchWindowMs,
      maxBatchSize: config.maxBatchSize,
    });

    // Start polling loop
    this.pollingInterval = setInterval(
      () => this.pollAndResolve(),
      config.pollingIntervalMs
    );

    // Initial poll
    await this.pollAndResolve();
  }

  /**
   * Stop monitoring
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    this.isRunning = false;

    if (this.pollingInterval) {
      clearInterval(this.pollingInterval);
      this.pollingInterval = null;
    }

    // Process remaining batch
    if (this.batchQueue.size > 0) {
      logger.info('Processing remaining batch before shutdown', {
        size: this.batchQueue.size,
      });
      await this.processBatch();
    }

    logger.info('Stopped EventMonitorService');
  }

  /**
   * Main polling and resolution loop
   */
  private async pollAndResolve(): Promise<void> {
    try {
      // Query pending events
      const pendingEvents = await this.suiService.queryPendingEvents();
      pendingEventsGauge.set(pendingEvents.length);

      if (pendingEvents.length === 0) {
        logger.debug('No pending events to resolve');
        return;
      }

      logger.info('Found pending events', { count: pendingEvents.length });

      // Add events to batch queue
      for (const event of pendingEvents) {
        await this.addToBatch(event);
      }

      // Check if batch window expired or max size reached
      const timeSinceLastBatch = Date.now() - this.lastBatchTime;
      const shouldProcess =
        timeSinceLastBatch >= config.batchWindowMs ||
        this.batchQueue.size >= config.maxBatchSize;

      if (shouldProcess && this.batchQueue.size > 0) {
        await this.processBatch();
      }
    } catch (error: any) {
      logger.error('Error in polling loop', {
        error: error.message,
        stack: error.stack,
      });
      resolutionErrorsTotal.inc({ error_type: 'polling' });
    }
  }

  /**
   * Add event to batch queue
   */
  private async addToBatch(event: PredictionEvent): Promise<void> {
    if (event.oracleFeedId.toLowerCase() !== config.pythFeedSuiUsd.toLowerCase()) {
      logger.debug('Skipping unsupported feed for v1 keeper', {
        eventId: event.id,
        oracleFeedId: event.oracleFeedId,
      });
      return;
    }

    // Check if already in batch
    if (this.batchQueue.has(event.id)) {
      return;
    }

    // Check if already locked by another instance
    const isLocked = await this.lockService.isLocked(event.id);
    if (isLocked) {
      logger.debug('Event already locked, skipping', { eventId: event.id });
      return;
    }

    // Calculate priority (events closer to betting end time have higher priority)
    const timeSinceEnd = Date.now() - event.bettingEndTime;
    const priority = timeSinceEnd;

    const task: ResolutionTask = {
      eventId: event.id,
      feedId: event.oracleFeedId,
      targetPrice: event.targetPrice,
      priority,
      createdAt: Date.now(),
    };

    this.batchQueue.set(event.id, task);

    logger.debug('Added event to batch queue', {
      eventId: event.id,
      feedId: event.oracleFeedId,
      symbol: FEED_ID_TO_SYMBOL[event.oracleFeedId] || 'Unknown',
      queueSize: this.batchQueue.size,
    });
  }

  /**
   * Process batch of events
   */
  private async processBatch(): Promise<void> {
    if (this.batchQueue.size === 0) {
      return;
    }

    const batchSize = this.batchQueue.size;
    logger.info('Processing resolution batch', { size: batchSize });

    // Sort by priority (higher = more urgent)
    const tasks = Array.from(this.batchQueue.values()).sort(
      (a, b) => b.priority - a.priority
    );

    // Group by feed ID for batch price fetching
    const feedIds = [...new Set(tasks.map((t) => t.feedId))];
    
    logger.debug('Fetching batch prices', {
      feedIds: feedIds.map(id => FEED_ID_TO_SYMBOL[id] || id),
    });

    // Fetch all required price updates from Hermes
    const priceMap = await this.pythService.getBatchPrices(feedIds);

    // Process each task
    const results = await Promise.allSettled(
      tasks.map((task) => this.resolveEvent(task, priceMap))
    );

    // Count successes and failures
    const succeeded = results.filter((r) => r.status === 'fulfilled').length;
    const failed = results.filter((r) => r.status === 'rejected').length;

    logger.info('Batch processing complete', {
      total: batchSize,
      succeeded,
      failed,
    });

    // Clear batch queue
    this.batchQueue.clear();
    this.lastBatchTime = Date.now();

    // Cleanup expired locks
    await this.lockService.cleanupExpiredLocks();
  }

  /**
   * Resolve a single event
   */
  private async resolveEvent(
    task: ResolutionTask,
    priceMap: Map<string, any>
  ): Promise<void> {
    const { eventId, feedId } = task;

    try {
      // Try to acquire lock
      const lockAcquired = await this.lockService.tryLock(eventId);
      if (!lockAcquired) {
        logger.warn('Could not acquire lock for event', { eventId });
        return;
      }

      // Get Pyth update data
      const priceData = priceMap.get(feedId);
      if (!priceData) {
        logger.error('No price data for event', {
          eventId,
          feedId,
          symbol: FEED_ID_TO_SYMBOL[feedId] || 'Unknown',
        });
        resolutionErrorsTotal.inc({ error_type: 'missing_price' });
        await this.lockService.releaseLock(eventId);
        return;
      }

      // Get event details to determine coin type
      const eventDetails = await this.suiService.getEventDetails(eventId);
      if (!eventDetails) {
        logger.error('Could not fetch event details', { eventId });
        resolutionErrorsTotal.inc({ error_type: 'fetch_details' });
        await this.lockService.releaseLock(eventId);
        return;
      }

      // Execute resolution
      const coinType = '0x2::sui::SUI'; // Default to SUI, can be enhanced
      const result = await this.suiService.executeResolution(
        eventId,
        coinType,
        priceData
      );

      if (result.success) {
        eventsResolvedTotal.inc({ status: 'success', event_type: 'crypto' });
        logger.info('Successfully resolved event', {
          eventId,
          txDigest: result.txDigest,
          winningOutcome: result.winningOutcome,
          symbol: FEED_ID_TO_SYMBOL[feedId] || 'Unknown',
        });
      } else {
        eventsResolvedTotal.inc({ status: 'failure', event_type: 'crypto' });
        resolutionErrorsTotal.inc({ error_type: 'execution' });
        logger.error('Failed to resolve event', {
          eventId,
          error: result.error,
        });
      }

      // Release lock
      await this.lockService.releaseLock(eventId);
    } catch (error: any) {
      logger.error('Error resolving event', {
        eventId,
        error: error.message,
        stack: error.stack,
      });
      resolutionErrorsTotal.inc({ error_type: 'unknown' });
      await this.lockService.releaseLock(eventId);
    }
  }

  /**
   * Get current queue status
   */
  getStatus(): {
    isRunning: boolean;
    queueSize: number;
    lastBatchTime: number;
  } {
    return {
      isRunning: this.isRunning,
      queueSize: this.batchQueue.size,
      lastBatchTime: this.lastBatchTime,
    };
  }
}
