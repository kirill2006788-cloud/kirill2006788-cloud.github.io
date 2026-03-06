import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { cors: true });
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const express = require('express');
  app.use(express.json({ limit: '50mb' }));
  app.use(express.urlencoded({ extended: true, limit: '50mb' }));
  app.setGlobalPrefix('api');
  await app.listen(3000, '0.0.0.0');
}
bootstrap();
