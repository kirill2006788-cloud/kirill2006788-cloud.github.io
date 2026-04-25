import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { AppModule } from './app.module';

async function bootstrap() {
  const defaultOrigins = [
    'https://admin.trezv7777.ru', 'https://trezv7777.ru', 'https://api.trezv7777.ru',
    'http://admin.trezv7777.ru', 'http://trezv7777.ru', 'http://api.trezv7777.ru',
    'http://194.67.84.155', 'https://194.67.84.155',
  ];
  const allowedOrigins = (process.env.CORS_ORIGINS || defaultOrigins.join(','))
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean);
  const app = await NestFactory.create(AppModule, {
    cors: {
      origin: (origin: string | undefined, cb: (err: Error | null, allow?: boolean) => void) => {
        if (!origin) return cb(null, true);
        if (allowedOrigins.includes(origin)) return cb(null, true);
        if (origin.startsWith('http://localhost') || origin.startsWith('http://127.0.0.1')) return cb(null, true);
        console.warn(`CORS rejected origin: ${origin}`);
        return cb(null, true);
      },
      credentials: true,
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const express = require('express');
  app.use(express.json({ limit: process.env.BODY_LIMIT || '5mb' }));
  app.use(express.urlencoded({ extended: true, limit: process.env.BODY_LIMIT || '5mb' }));
  app.use((req: any, res: any, next: any) => {
    const ip =
      (req.headers['x-forwarded-for']?.toString().split(',')[0] || req.ip || req.socket?.remoteAddress || 'unknown')
        .toString()
        .trim();
    const now = Date.now();
    const key = `${ip}:${req.path}`;
    const windowMs = Number(process.env.RATE_LIMIT_WINDOW_MS || 60_000);
    const limit = Number(process.env.RATE_LIMIT_MAX || 180);
    const g: any = globalThis as any;
    if (!g.__apiRateLimitMap) g.__apiRateLimitMap = new Map<string, { c: number; t: number }>();
    const map: Map<string, { c: number; t: number }> = g.__apiRateLimitMap;
    const prev = map.get(key);
    if (!prev || now - prev.t > windowMs) {
      map.set(key, { c: 1, t: now });
      return next();
    }
    prev.c += 1;
    if (prev.c > limit) {
      return res.status(429).json({ ok: false, error: 'Too many requests' });
    }
    return next();
  });
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      transform: true,
      forbidNonWhitelisted: false,
    }),
  );
  app.setGlobalPrefix('api');
  await app.listen(3000, '0.0.0.0');
}
bootstrap();
