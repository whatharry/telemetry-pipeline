import { Global, Module } from '@nestjs/common';
import { DbService } from './db.service';

// Global so the pool is a genuine singleton -- one pool per process, not one per
// importing module.
@Global()
@Module({
  providers: [DbService],
  exports: [DbService],
})
export class DbModule {}
