import Redis from 'ioredis';
import { config } from '../config';
import logger from '../utils/logger';
import { activeLocksGauge } from '../utils/metrics';

export class ResolutionLockService {
  private redis: Redis;
  private lockPrefix = 'resolution:lock:';
  private activeLocks: Set<string> = new Set();

  constructor() {
    this.redis = new Redis({
      host: config.redis.host,
      port: config.redis.port,
      password: config.redis.password,
      db: config.redis.db,
      retryStrategy: (times) => {
        const delay = Math.min(times * 50, 2000);
        return delay;
      },
    });

    this.redis.on('connect', () => {
      logger.info('Connected to Redis');
    });

    this.redis.on('error', (error) => {
      logger.error('Redis connection error', { error: error.message });
    });
  }

  /**
   * Try to acquire lock for event resolution
   */
  async tryLock(eventId: string): Promise<boolean> {
    const key = this.lockPrefix + eventId;
    const ttl = config.resolutionLockTtlSec;

    try {
      // SET NX (only if not exists) with expiry
      const result = await this.redis.set(
        key,
        Date.now().toString(),
        'EX',
        ttl,
        'NX'
      );

      if (result === 'OK') {
        this.activeLocks.add(eventId);
        activeLocksGauge.set(this.activeLocks.size);

        logger.debug('Acquired resolution lock', { eventId, ttl });
        return true;
      }

      logger.debug('Failed to acquire lock (already locked)', { eventId });
      return false;
    } catch (error: any) {
      logger.error('Error acquiring lock', {
        eventId,
        error: error.message,
      });
      return false;
    }
  }

  /**
   * Release lock for event resolution
   */
  async releaseLock(eventId: string): Promise<void> {
    const key = this.lockPrefix + eventId;

    try {
      await this.redis.del(key);
      this.activeLocks.delete(eventId);
      activeLocksGauge.set(this.activeLocks.size);

      logger.debug('Released resolution lock', { eventId });
    } catch (error: any) {
      logger.error('Error releasing lock', {
        eventId,
        error: error.message,
      });
    }
  }

  /**
   * Check if event is currently locked
   */
  async isLocked(eventId: string): Promise<boolean> {
    const key = this.lockPrefix + eventId;

    try {
      const exists = await this.redis.exists(key);
      return exists === 1;
    } catch (error: any) {
      logger.error('Error checking lock', {
        eventId,
        error: error.message,
      });
      return true; // Assume locked on error (fail-safe)
    }
  }

  /**
   * Get time remaining on lock (in seconds)
   */
  async getLockTTL(eventId: string): Promise<number> {
    const key = this.lockPrefix + eventId;

    try {
      const ttl = await this.redis.ttl(key);
      return ttl > 0 ? ttl : 0;
    } catch (error: any) {
      logger.error('Error getting lock TTL', {
        eventId,
        error: error.message,
      });
      return 0;
    }
  }

  /**
   * Extend lock TTL (for long-running resolutions)
   */
  async extendLock(eventId: string, additionalSeconds: number): Promise<boolean> {
    const key = this.lockPrefix + eventId;

    try {
      const currentTTL = await this.redis.ttl(key);
      if (currentTTL > 0) {
        const newTTL = currentTTL + additionalSeconds;
        await this.redis.expire(key, newTTL);
        
        logger.debug('Extended resolution lock', {
          eventId,
          oldTTL: currentTTL,
          newTTL,
        });
        return true;
      }
      return false;
    } catch (error: any) {
      logger.error('Error extending lock', {
        eventId,
        error: error.message,
      });
      return false;
    }
  }

  /**
   * Clean up expired locks from tracking set
   */
  async cleanupExpiredLocks(): Promise<void> {
    const expiredLocks: string[] = [];

    for (const eventId of this.activeLocks) {
      const isLocked = await this.isLocked(eventId);
      if (!isLocked) {
        expiredLocks.push(eventId);
      }
    }

    for (const eventId of expiredLocks) {
      this.activeLocks.delete(eventId);
    }

    activeLocksGauge.set(this.activeLocks.size);

    if (expiredLocks.length > 0) {
      logger.debug('Cleaned up expired locks', {
        count: expiredLocks.length,
      });
    }
  }

  /**
   * Close Redis connection
   */
  async close(): Promise<void> {
    await this.redis.quit();
    logger.info('Closed Redis connection');
  }
}
