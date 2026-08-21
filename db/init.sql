-- TimescaleDB schema for device telemetry.
--
-- Design notes:
--   * Raw readings live in a hypertable chunked by 1 day. At the ingest rates this
--     stack targets (~10k readings/sec) that keeps chunks in the low hundreds of MB,
--     which is the range where TimescaleDB's chunk exclusion stays effective.
--   * Dashboards never query the raw table. They read continuous aggregates, which
--     are materialised incrementally rather than recomputed per request.
--   * Compression after 7 days, retention after 90. Both are policies, not cron jobs,
--     so they survive restarts.

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE devices (
    device_id   TEXT PRIMARY KEY,
    model       TEXT        NOT NULL,
    fleet       TEXT        NOT NULL,
    registered  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE readings (
    time        TIMESTAMPTZ      NOT NULL,
    device_id   TEXT             NOT NULL REFERENCES devices (device_id),
    temperature DOUBLE PRECISION,
    voltage     DOUBLE PRECISION,
    rpm         INTEGER,
    error_code  SMALLINT
);

-- 1-day chunks. Tune with the ingest rate: aim for chunks that fit comfortably in
-- memory alongside the indexes, roughly 25% of RAM across all active chunks.
SELECT create_hypertable('readings', 'time', chunk_time_interval => INTERVAL '1 day');

-- Most queries filter by device over a time range, so device_id leads and time
-- descends -- that ordering serves both the filter and the ORDER BY.
CREATE INDEX ON readings (device_id, time DESC);

-- Sparse index: error_code is NULL on the overwhelming majority of rows, so a
-- partial index stays small while still making fault queries fast.
CREATE INDEX ON readings (error_code, time DESC) WHERE error_code IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Continuous aggregates
-- ---------------------------------------------------------------------------
-- Dashboards hit these, never `readings`. A 24h dashboard query against raw data
-- scans millions of rows; against readings_1m it scans ~1,440 per device.

CREATE MATERIALIZED VIEW readings_1m
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 minute', time) AS bucket,
    device_id,
    avg(temperature)  AS avg_temp,
    max(temperature)  AS max_temp,
    min(temperature)  AS min_temp,
    avg(voltage)      AS avg_voltage,
    avg(rpm)::INTEGER AS avg_rpm,
    count(*)          AS sample_count,
    count(error_code) AS error_count
FROM readings
GROUP BY bucket, device_id
WITH NO DATA;

CREATE MATERIALIZED VIEW readings_1h
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', bucket) AS bucket,
    device_id,
    avg(avg_temp)     AS avg_temp,
    max(max_temp)     AS max_temp,
    min(min_temp)     AS min_temp,
    avg(avg_voltage)  AS avg_voltage,
    sum(sample_count) AS sample_count,
    sum(error_count)  AS error_count
FROM readings_1m
GROUP BY 1, 2
WITH NO DATA;

-- Hierarchical rollup: 1h builds on 1m rather than re-scanning raw readings.

SELECT add_continuous_aggregate_policy('readings_1m',
    start_offset => INTERVAL '3 hours',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute');

SELECT add_continuous_aggregate_policy('readings_1h',
    start_offset => INTERVAL '3 days',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour');

-- end_offset keeps the aggregate off the newest bucket, which is still receiving
-- writes. Without it, late-arriving readings land in an already-materialised bucket
-- and silently go missing from dashboards.

-- ---------------------------------------------------------------------------
-- Compression and retention
-- ---------------------------------------------------------------------------
ALTER TABLE readings SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id',
    timescaledb.compress_orderby   = 'time DESC'
);

SELECT add_compression_policy('readings', INTERVAL '7 days');
SELECT add_retention_policy('readings',  INTERVAL '90 days');

-- Aggregates outlive the raw data they came from: raw drops at 90 days, the
-- hourly rollup is kept for two years.
SELECT add_retention_policy('readings_1h', INTERVAL '2 years');
