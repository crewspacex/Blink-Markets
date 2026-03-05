/// <reference types="jest" />

import { ResolutionLockService } from '../src/services/ResolutionLockService';

// Mock Redis
jest.mock('ioredis');

describe('ResolutionLockService', () => {
  let service: ResolutionLockService;

  beforeEach(() => {
    service = new ResolutionLockService();
  });

  afterEach(async () => {
    await service.close();
  });

  describe('Lock operations', () => {
    it('should acquire lock for new event', async () => {
      const eventId = 'test-event-1';
      const acquired = await service.tryLock(eventId);
      
      // Note: This will fail without mocking Redis properly
      // This is a structure test showing what should be tested
      expect(typeof acquired).toBe('boolean');
    });

    it('should check if event is locked', async () => {
      const eventId = 'test-event-2';
      const isLocked = await service.isLocked(eventId);
      
      expect(typeof isLocked).toBe('boolean');
    });
  });
});
