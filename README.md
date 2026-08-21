# Telemetry Pipeline

Device telemetry from ingest to dashboard: a Python generator feeding a NestJS ingest API,
stored in TimescaleDB as a hypertable with continuous aggregates, and visualised in Grafana.

One command brings the whole stack up.

```bash
docker compose up --build
```

- Grafana — <http://localhost:3011> (anonymous viewer access, no login needed)
- Ingest API — <http://localhost:3010/health>
- TimescaleDB — `localhost:5433` (`telemetry` / `telemetry`)

Host ports are deliberately off the defaults so the stack does not collide with a Postgres or
dev server you already have running. Override with `DB_PORT`, `INGEST_PORT`, `GRAFANA_PORT`.

Data starts appearing on the dashboard within about a minute — the first continuous
aggregate refresh has to run before the panels have anything to draw.

---

## Why this exists

Time-series workloads break the habits that work everywhere else. Row-at-a-time inserts fall
over, dashboards that query raw data get slower every day they run, and the naive schema is
fine for a week and unusable at three months. This is a small, complete example of handling
those three problems properly.

## Architecture

```
┌───────────┐   batched    ┌────────────┐   multi-row   ┌──────────────┐
│ generator │──── POST ───▶│   ingest   │──── INSERT ──▶│ TimescaleDB  │
│  (Python) │   500/req    │  (NestJS)  │   1 stmt      │  hypertable  │
└───────────┘              └────────────┘               └──────┬───────┘
      ▲                          │                             │
      │      429 backpressure    │                    continuous aggregates
      └──────────────────────────┘                       (1 min → 1 hour)
                                                                │
                                                         ┌──────▼───────┐
                                                         │   Grafana    │
                                                         └──────────────┘
```

### Ingest

Readings arrive in batches and are written as a **single multi-row `INSERT`**. The obvious
implementation — loop, await one insert per reading — costs a network round trip each time and
collapses under load. One parameterised statement turns 500 round trips into one. Values are
still bound as parameters, never interpolated, so it stays injection-safe.

Two guards bound the damage a client can do:

- **Batch cap** (`MAX_BATCH`, default 1000) limits the work one request can demand.
- **Saturation check** returns `429` once the connection pool has more than `PG_MAX_WAITING`
  requests queued. A well-behaved client backs off; a badly-behaved one at least cannot take
  the database down. The alternative — every request quietly blocking on
  `connectionTimeoutMillis` — stalls the whole service at once and looks like a hang rather
  than a failure.

Payloads are validated with `class-validator` against *physical* bounds, not arbitrary ones. A
device reporting 900°C is an upstream parsing fault, and admitting it corrupts every average it
lands in — a single bad row visibly skews an hourly bucket.

`/health` reports pool statistics alongside liveness, because a load balancer that only asks
"is the process up" will happily route traffic to an instance whose pool is fully exhausted.

### Storage

`readings` is a hypertable chunked at one day. Chunk sizing is the main tuning knob: aim for
all actively-written chunks to fit comfortably in memory alongside their indexes.

Two indexes, each earning its place:

- `(device_id, time DESC)` — serves both the filter and the ordering of the common query.
- `(error_code, time DESC) WHERE error_code IS NOT NULL` — partial, because `error_code` is
  NULL on the overwhelming majority of rows. A full index here would be mostly empty entries.

### Continuous aggregates

**Dashboards never touch the raw table.** A 24-hour panel against raw readings scans millions
of rows; against `readings_1m` it scans roughly 1,440 per device. The rollups are materialised
incrementally rather than recomputed per request.

`readings_1h` is built from `readings_1m` rather than from raw data — a hierarchical rollup, so
the hourly refresh re-reads minute buckets instead of re-scanning the hypertable.

The `end_offset` on each policy matters more than it looks. It keeps the aggregate off the
newest bucket, which is still receiving writes. Without it, late-arriving readings land in an
already-materialised bucket and silently vanish from every dashboard — the kind of bug that
surfaces weeks later as "the numbers don't match."

### Lifecycle

Compression at 7 days (segmented by `device_id`, ordered by `time DESC`), retention at 90 days.
The hourly rollup is kept for two years, so aggregates outlive the raw data they came from —
which is almost always what you actually want from historical telemetry.

Both are TimescaleDB policies rather than cron jobs, so they survive restarts.

---

## Measured throughput

Single ingest container against a single TimescaleDB container, both on one Apple M1 Pro
(8 cores). Full validation enabled. Numbers include HTTP, validation, and the database round
trip -- not just the insert.

| Batch size | Readings/sec | p50 latency | p95 latency |
|---:|---:|---:|---:|
| 100 | 13,987 | 7 ms | 8 ms |
| 500 | 20,329 | 24 ms | 29 ms |
| 1,000 | 24,508 | 41 ms | 44 ms |

Two things worth reading off this table.

**Batching dominates.** Going from 100 to 1,000 readings per request buys roughly 75% more
throughput, because the per-request costs -- HTTP parsing, a pool checkout, one round trip --
are amortised across more rows. The same workload sent one reading at a time is roughly two
orders of magnitude slower.

**Validation is not free.** With validation disabled the same 1,000-row batch reaches about
44,000 readings/sec, so strict validation costs roughly 45% of peak throughput. That is a real
tradeoff and worth stating rather than hiding: it buys the guarantee that a malformed reading
never reaches an aggregate, where a single bad row visibly skews an hourly average and is
painful to unpick after the fact. At these volumes the ceiling is far above what the fleet
produces, so correctness is the right side to err on. A workload actually pushing 40k/sec should
revisit it.

Reproduce with `--devices 1000 --interval 0.5` on the generator, or POST batches directly.

## Testing

```bash
cd ingest && npm install && npm test
```

18 tests across two suites. They cover the properties that actually matter for correctness under
load: that a batch produces one statement rather than N, that every value is bound rather than
interpolated, that optional fields become NULL instead of shifting the tuple, that dashboard
queries hit the aggregate rather than the hypertable, and that every physical bound on the DTO
holds against out-of-range values, path traversal, and injection-shaped device ids.

The DTO bounds have their own suite for a reason. Array bodies need an explicit `ParseArrayPipe`
with the item type -- TypeScript array types erase at runtime, so a bare `@Body() r: ReadingDto[]`
leaves the global `ValidationPipe` with nothing to validate against and it waves every element
through. That failure is silent: the endpoint keeps returning 202 and bad rows keep landing.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `PG_POOL_MAX` | 20 | Pool ceiling — sized to the database, not the app |
| `PG_MAX_WAITING` | 10 | Queued requests before shedding with 429 |
| `MAX_BATCH` | 1000 | Largest accepted batch |
| `PORT` | 3000 | Ingest listen port |

Generator flags: `--devices`, `--interval`, `--batch-size`.

```bash
docker compose run --rm generator --devices 1000 --interval 0.5
```

## API

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/readings` | Batched reading ingest |
| `POST` | `/devices` | Register or update devices (upsert) |
| `GET` | `/devices/:id/stats?hours=24` | Per-device rollup from the aggregate |
| `GET` | `/health` | Liveness plus pool saturation |

## Limitations

Worth stating plainly, since none of these are oversights:

- **No authentication.** The ingest endpoint is open. Real deployments need device identity —
  mTLS or signed tokens — and this has neither.
- **No dead-letter path.** A batch that fails validation is rejected wholesale and the client
  is expected to retry. Production systems usually want the valid rows kept and the bad ones
  quarantined for inspection.
- **At-most-once delivery.** If ingest crashes between accepting a request and committing, that
  batch is gone. Durability would mean a queue in front — Kafka or NATS — with the API
  acknowledging only after the write is durable.
- **Single ingest instance.** It scales horizontally without changes, but nothing here proves
  that.
- **Synthetic data.** The generator models drift and correlated faults, but real device fleets
  produce failure modes no simulator anticipates.

## License

MIT
