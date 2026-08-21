import { Module } from '@nestjs/common';

import { DbModule } from './db/db.module';
import { TelemetryModule } from './telemetry/telemetry.module';
import { HealthController } from './health.controller';

@Module({
  imports: [DbModule, TelemetryModule],
  controllers: [HealthController],
})
export class AppModule {}
