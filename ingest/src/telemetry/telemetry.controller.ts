import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  HttpException,
  HttpStatus,
  Param,
  ParseArrayPipe,
  ParseIntPipe,
  Post,
  Query,
} from '@nestjs/common';
import { DbService } from '../db/db.service';
import { TelemetryService } from './telemetry.service';
import { DeviceDto, ReadingDto } from './dto/reading.dto';

const MAX_BATCH = Number(process.env.MAX_BATCH ?? 1000);

@Controller()
export class TelemetryController {
  constructor(
    private readonly telemetry: TelemetryService,
    private readonly db: DbService,
  ) {}

  /**
   * Batched ingest.
   *
   * Two guards matter here. The batch cap bounds how much work a single request
   * can demand, and the saturation check sheds load with a 429 before the pool
   * queue grows without limit. A generator that respects 429 will back off; one
   * that does not at least cannot take the database down with it.
   */
  @Post('readings')
  @HttpCode(HttpStatus.ACCEPTED)
  async ingest(
    // ParseArrayPipe is required, not decorative: TypeScript array types erase at
    // runtime, so a bare `@Body() readings: ReadingDto[]` leaves the global
    // ValidationPipe with no item type and it waves every element through.
    @Body(new ParseArrayPipe({ items: ReadingDto, whitelist: true, forbidNonWhitelisted: true }))
    readings: ReadingDto[],
  ) {
    if (readings.length > MAX_BATCH) {
      throw new BadRequestException(
        `batch too large: ${readings.length} > ${MAX_BATCH}`,
      );
    }

    // Shed load before the pool queue grows without bound. 429 tells a
    // well-behaved client to back off; the alternative is every request hanging
    // on connectionTimeoutMillis and the whole service stalling at once.
    if (this.db.isSaturated()) {
      throw new HttpException(
        'ingest saturated, retry shortly',
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }

    const inserted = await this.telemetry.insertReadings(readings);
    return { inserted };
  }

  @Post('devices')
  @HttpCode(HttpStatus.ACCEPTED)
  async register(
    @Body(new ParseArrayPipe({ items: DeviceDto, whitelist: true, forbidNonWhitelisted: true }))
    devices: DeviceDto[],
  ) {
    const registered = await this.telemetry.registerDevices(devices);
    return { registered };
  }

  @Get('devices/:id/stats')
  stats(
    @Param('id') id: string,
    @Query('hours', new ParseIntPipe({ optional: true })) hours = 24,
  ) {
    return this.telemetry.recentStats(id, hours);
  }
}
