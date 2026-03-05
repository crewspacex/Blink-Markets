import express from 'express';
import { register } from './utils/metrics';
import { SuiInteractionService } from './services/SuiInteractionService';
import { PythOracleService } from './services/PythOracleService';
import { ResolutionLockService } from './services/ResolutionLockService';
import { EventMonitorService } from './services/EventMonitorService';
import { config } from './config';
import logger from './utils/logger';

async function main() {
  logger.info('Starting Blinkmarket Keeper Service', {
    version: '1.0.0',
    network: config.suiNetwork,
    oracleAddress: config.oracleAddress,
  });

  // Initialize services
  const suiService = new SuiInteractionService();
  const pythService = new PythOracleService();
  const lockService = new ResolutionLockService();
  const monitorService = new EventMonitorService(
    suiService,
    pythService,
    lockService
  );

  // Setup graceful shutdown
  const shutdown = async () => {
    logger.info('Shutting down gracefully...');
    
    await monitorService.stop();
    await lockService.close();
    
    logger.info('Shutdown complete');
    process.exit(0);
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  // Start HTTP server for health checks and metrics
  const app = express();

  app.get('/health', (req, res) => {
    const status = monitorService.getStatus();
    res.json({
      status: 'healthy',
      uptime: process.uptime(),
      monitor: status,
    });
  });

  app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  });

  app.get('/status', (req, res) => {
    const status = monitorService.getStatus();
    res.json({
      service: 'blinkmarket-keeper',
      version: '1.0.0',
      network: config.suiNetwork,
      oracle: config.oracleAddress,
      monitor: status,
      config: {
        pollingIntervalMs: config.pollingIntervalMs,
        batchWindowMs: config.batchWindowMs,
        maxBatchSize: config.maxBatchSize,
      },
    });
  });

  const port = config.prometheusPort;
  app.listen(port, () => {
    logger.info(`HTTP server listening on port ${port}`);
  });

  // Start event monitoring
  await monitorService.start();

  logger.info('Keeper service started successfully');
}

// Run main
main().catch((error) => {
  logger.error('Fatal error in main', {
    error: error.message,
    stack: error.stack,
  });
  process.exit(1);
});
