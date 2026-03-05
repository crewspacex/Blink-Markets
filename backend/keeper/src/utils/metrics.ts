import { Registry, Counter, Gauge, Histogram } from 'prom-client';

export const register = new Registry();

// Counters
export const eventsResolvedTotal = new Counter({
  name: 'blinkmarket_events_resolved_total',
  help: 'Total number of events resolved',
  labelNames: ['status', 'event_type'],
  registers: [register],
});

export const oracleApiCallsTotal = new Counter({
  name: 'blinkmarket_oracle_api_calls_total',
  help: 'Total number of oracle API calls',
  labelNames: ['status'],
  registers: [register],
});

export const resolutionErrorsTotal = new Counter({
  name: 'blinkmarket_resolution_errors_total',
  help: 'Total number of resolution errors',
  labelNames: ['error_type'],
  registers: [register],
});

// Gauges
export const pendingEventsGauge = new Gauge({
  name: 'blinkmarket_pending_events',
  help: 'Number of events pending resolution',
  registers: [register],
});

export const activeLocksGauge = new Gauge({
  name: 'blinkmarket_active_locks',
  help: 'Number of active resolution locks',
  registers: [register],
});

// Histograms
export const resolutionDurationHistogram = new Histogram({
  name: 'blinkmarket_resolution_duration_seconds',
  help: 'Duration of event resolution',
  buckets: [0.1, 0.5, 1, 2, 5, 10],
  registers: [register],
});

export const oracleApiDurationHistogram = new Histogram({
  name: 'blinkmarket_oracle_api_duration_seconds',
  help: 'Duration of oracle API calls',
  buckets: [0.05, 0.1, 0.25, 0.5, 1, 2],
  registers: [register],
});

export const gasUsedHistogram = new Histogram({
  name: 'blinkmarket_gas_used',
  help: 'Gas used for resolutions',
  buckets: [1000000, 5000000, 10000000, 50000000, 100000000],
  registers: [register],
});
