import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import { json } from 'express';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { bufferLogs: true });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,           // strip properties with no DTO decorator
      forbidNonWhitelisted: true, // ...and reject the request that sent them
      transform: true,
      validationError: { target: false, value: false },
    }),
  );

  // Telemetry batches are large. Default body limit is 100kb, which a 500-reading
  // batch will exceed.
  app.use(json({ limit: '5mb' }));

  // Let in-flight inserts finish when the container gets SIGTERM. Without this a
  // deploy drops whatever batch was mid-flight.
  app.enableShutdownHooks();

  const port = Number(process.env.PORT ?? 3000);
  await app.listen(port, '0.0.0.0');
  new Logger('bootstrap').log(`ingest listening on ${port}`);
}

bootstrap();
