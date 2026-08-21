import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { ReadingDto } from './reading.dto';

/**
 * These bounds are the last line of defence before bad data reaches an aggregate,
 * where one row can visibly skew an hourly average. They are worth pinning.
 */
const check = (payload: Record<string, unknown>) =>
  validateSync(plainToInstance(ReadingDto, payload), {
    whitelist: true,
    forbidNonWhitelisted: true,
  });

describe('ReadingDto', () => {
  it('accepts a plausible reading', () => {
    expect(check({ device_id: 'dev-0001', temperature: 45.5, voltage: 12.6, rpm: 2000 }))
      .toHaveLength(0);
  });

  it('accepts a reading carrying only a device id', () => {
    expect(check({ device_id: 'dev-0001' })).toHaveLength(0);
  });

  it.each([
    ['temperature above physical range', { device_id: 'd1', temperature: 900 }],
    ['temperature below physical range', { device_id: 'd1', temperature: -273 }],
    ['negative voltage', { device_id: 'd1', voltage: -5 }],
    ['rpm beyond any real device', { device_id: 'd1', rpm: 999999 }],
    ['non-numeric temperature', { device_id: 'd1', temperature: 'hot' }],
  ])('rejects %s', (_label, payload) => {
    expect(check(payload).length).toBeGreaterThan(0);
  });

  it.each([
    ['path traversal', '../etc/passwd'],
    ['sql-ish punctuation', "d1'; DROP TABLE readings--"],
    ['empty', ''],
    ['over 64 chars', 'd'.repeat(65)],
  ])('rejects device_id: %s', (_label, device_id) => {
    expect(check({ device_id }).length).toBeGreaterThan(0);
  });

  it('rejects unknown properties rather than ignoring them', () => {
    expect(check({ device_id: 'dev-0001', injected: 'x' }).length).toBeGreaterThan(0);
  });
});
