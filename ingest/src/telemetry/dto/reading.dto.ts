import {
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  Matches,
  Max,
  Min,
} from 'class-validator';

/**
 * Bounds here are physical, not arbitrary. A device reporting 900°C is a parsing
 * fault upstream, and letting it through corrupts every average it lands in --
 * one bad row can visibly skew an hourly aggregate.
 */
export class ReadingDto {
  @IsString()
  @Matches(/^[a-zA-Z0-9_-]{1,64}$/, {
    message: 'device_id must be 1-64 chars of [a-zA-Z0-9_-]',
  })
  device_id!: string;

  @IsOptional()
  @IsNumber()
  @Min(-50)
  @Max(200)
  temperature?: number;

  @IsOptional()
  @IsNumber()
  @Min(0)
  @Max(60)
  voltage?: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(20000)
  rpm?: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(32767)
  error_code?: number | null;

  /** Optional client timestamp; the server stamps arrival when absent. */
  @IsOptional()
  @IsString()
  time?: string;
}

export class DeviceDto {
  @IsString()
  @Matches(/^[a-zA-Z0-9_-]{1,64}$/)
  device_id!: string;

  @IsString()
  model!: string;

  @IsString()
  fleet!: string;
}
