import {
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';
import { Pool, PoolClient, QueryResult } from 'pg';

@Injectable()
export class DbService implements OnModuleInit, OnModuleDestroy {
  private readonly log = new Logger(DbService.name);
  private pool!: Pool;

  onModuleInit() {
    this.pool = new Pool({
      host: process.env.PGHOST ?? 'localhost',
      port: Number(process.env.PGPORT ?? 5432),
      user: process.env.PGUSER ?? 'telemetry',
      password: process.env.PGPASSWORD ?? 'telemetry',
      database: process.env.PGDATABASE ?? 'telemetry',
      // Sized to the database, not the app. Postgres degrades past a few hundred
      // connections, so the ceiling belongs here rather than in an autoscaler.
      max: Number(process.env.PG_POOL_MAX ?? 20),
      idleTimeoutMillis: 30_000,
      // Fail fast when the pool is exhausted so the controller can return 429
      // instead of holding the request open indefinitely.
      connectionTimeoutMillis: 2_000,
    });

    this.pool.on('error', (err) =>
      this.log.error(`idle client error: ${err.message}`),
    );
  }

  async onModuleDestroy() {
    await this.pool?.end();
  }

  query<T extends Record<string, any> = any>(
    sql: string,
    params?: unknown[],
  ): Promise<QueryResult<T>> {
    return this.pool.query(sql, params as any[]);
  }

  /** Runs `fn` inside a transaction, releasing the client on every path. */
  async transaction<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  }

  poolStats() {
    return {
      total: this.pool.totalCount,
      idle: this.pool.idleCount,
      waiting: this.pool.waitingCount,
    };
  }

  /** True when every connection is busy and requests are already queueing. */
  isSaturated(): boolean {
    return this.pool.waitingCount > Number(process.env.PG_MAX_WAITING ?? 10);
  }
}
