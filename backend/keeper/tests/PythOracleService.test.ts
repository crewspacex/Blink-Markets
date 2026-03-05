/// <reference types="jest" />

import { PythOracleService } from '../src/services/PythOracleService';

describe('PythOracleService', () => {
  let service: PythOracleService;

  beforeEach(() => {
    service = new PythOracleService();
  });

  describe('isValidFeedId', () => {
    it('should validate correct feed IDs', () => {
      const validFeedId = '0x7404e3d104ea7841c3d9e6fd20adfe99b4ad586bc08d8f3bd3afef894cf184de';
      expect(service.isValidFeedId(validFeedId)).toBe(true);
    });

    it('should validate feed IDs without 0x prefix', () => {
      const validFeedId = '7404e3d104ea7841c3d9e6fd20adfe99b4ad586bc08d8f3bd3afef894cf184de';
      expect(service.isValidFeedId(validFeedId)).toBe(true);
    });

    it('should reject invalid feed IDs', () => {
      expect(service.isValidFeedId('0x123')).toBe(false);
      expect(service.isValidFeedId('invalid')).toBe(false);
      expect(service.isValidFeedId('')).toBe(false);
    });
  });

  describe('getLatestPrice', () => {
    it('should return null on invalid feed ID', async () => {
      const result = await service.getLatestPrice('invalid_feed_id');
      expect(result).toBeNull();
    });
  });
});
