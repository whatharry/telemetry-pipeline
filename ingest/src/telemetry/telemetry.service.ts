import { Injectable, Logger } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { DeviceDto, ReadingDto } from './dto/reading.dto';

@Injectable()
export class TelemetryService {
  private readonly log = new Logger(TelemetryService.name);

  constructor(private readonly db: DbService) {}

  /**
   * Inserts a batch as ONE multi-row statement.
   *
   * The obvious implementation -- looping and awaiting an INSERT per reading --
   * costs a network round trip each time and collapses under load. Building a
   * single parameterised statement turns 500 round trips into one. Parameters are
   * still bound, never interpolated, so this stays injection-safe.
   */
  async insertReadings(readings: ReadingDto[]): Promise<number> {
    if (readings.length === 0) return 0;

    const cols = 6;
    const values: unknown[] = [];
    const tuples: string[] = [];

    readings.forEach((r, i) => {
      const b = i * cols;
      tuples.push(
        `($${b + 1}, $${b + 2}, $${b + 3}, $${b + 4}, $${b + 5}, $${b + 6})`,
      );
      values.push(
        r.time ? new Date(r.time) : new Date(),
        r.device_id,
        r.temperature ?? null,
        r.voltage ?? null,
        r.rpm ?? null,
        r.error_code ?? null,
      );
    });

    const sql = `
      INSERT INTO readings (time, device_id, temperature, voltage, rpm, error_code)
      VALUES ${tuples.join(', ')}
    `;

    const result = await this.db.query(sql, values);
    return result.rowCount ?? 0;
  }

  /** Upsert so a restarted generator does not blow up on duplicate ids. */
  async registerDevices(devices: DeviceDto[]): Promise<number> {
    if (devices.length === 0) return 0;

    const values: unknown[] = [];
    const tuples: string[] = [];

    devices.forEach((d, i) => {
      const b = i * 3;
      tuples.push(`($${b + 1}, $${b + 2}, $${b + 3})`);
      values.push(d.device_id, d.model, d.fleet);
    });

    const sql = `
      INSERT INTO devices (device_id, model, fleet)
      VALUES ${tuples.join(', ')}
      ON CONFLICT (device_id) DO UPDATE
        SET model = EXCLUDED.model, fleet = EXCLUDED.fleet
    `;

    const result = await this.db.query(sql, values);
    return result.rowCount ?? 0;
  }

  /** Reads the continuous aggregate, never the raw hypertable. */
  async recentStats(deviceId: string, hours = 24) {
    const { rows } = await this.db.query(
      `SELECT bucket, avg_temp, max_temp, avg_voltage, avg_rpm, error_count
         FROM readings_1m
        WHERE device_id = $1
          AND bucket > now() - ($2 || ' hours')::INTERVAL
        ORDER BY bucket DESC`,
      [deviceId, hours],
    );
    return rows;
  }
}
