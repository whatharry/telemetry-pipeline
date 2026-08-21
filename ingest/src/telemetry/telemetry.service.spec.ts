import { Test } from '@nestjs/testing';
import { DbService } from '../db/db.service';
import { TelemetryService } from './telemetry.service';
import { ReadingDto } from './dto/reading.dto';

describe('TelemetryService', () => {
  let service: TelemetryService;
  let db: { query: jest.Mock };

  beforeEach(async () => {
    db = { query: jest.fn().mockResolvedValue({ rowCount: 0, rows: [] }) };
    const module = await Test.createTestingModule({
      providers: [TelemetryService, { provide: DbService, useValue: db }],
    }).compile();
    service = module.get(TelemetryService);
  });

  const reading = (over: Partial<ReadingDto> = {}): ReadingDto => ({
    device_id: 'dev-0001',
    temperature: 45.5,
    voltage: 12.6,
    rpm: 2000,
    ...over,
  });

  it('sends one statement for a whole batch, not one per reading', async () => {
    await service.insertReadings([reading(), reading(), reading()]);
    expect(db.query).toHaveBeenCalledTimes(1);
  });

  it('binds every column as a parameter rather than interpolating', async () => {
    await service.insertReadings([reading(), reading()]);
    const [sql, params] = db.query.mock.calls[0];
    expect(params).toHaveLength(12); // 2 readings x 6 columns
    expect(sql).toContain('$12');
    expect(sql).not.toContain('dev-0001'); // value never inlined into SQL
  });

  it('persists error_code instead of silently dropping it', async () => {
    await service.insertReadings([reading({ error_code: 203 })]);
    const [sql, params] = db.query.mock.calls[0];
    expect(sql).toContain('error_code');
    expect(params).toContain(203);
  });

  it('nulls absent optional fields rather than shifting the tuple', async () => {
    await service.insertReadings([
      { device_id: 'dev-0002' } as ReadingDto,
    ]);
    const [, params] = db.query.mock.calls[0];
    expect(params).toHaveLength(6);
    expect(params.slice(2)).toEqual([null, null, null, null]);
  });

  it('short-circuits on an empty batch', async () => {
    expect(await service.insertReadings([])).toBe(0);
    expect(db.query).not.toHaveBeenCalled();
  });

  it('queries the continuous aggregate, never the raw hypertable', async () => {
    await service.recentStats('dev-0001', 6);
    const [sql] = db.query.mock.calls[0];
    expect(sql).toContain('readings_1m');
    expect(sql).not.toMatch(/FROM\s+readings\b/);
  });
});
