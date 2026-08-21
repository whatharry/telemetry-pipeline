import { Controller, Get } from '@nestjs/common';
import { DbService } from './db/db.service';

@Controller('health')
export class HealthController {
  constructor(private readonly db: DbService) {}

  /**
   * Reports pool saturation alongside liveness. A load balancer that only checks
   * "is the process up" will happily route traffic to an instance whose pool is
   * fully exhausted.
   */
  @Get()
  async check() {
    const stats = this.db.poolStats();
    let dbOk = true;
    try {
      await this.db.query('SELECT 1');
    } catch {
      dbOk = false;
    }
    return {
      status: dbOk ? 'ok' : 'degraded',
      database: dbOk ? 'up' : 'down',
      pool: stats,
    };
  }
}
