import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';

@Injectable()
export class RedisService implements OnModuleDestroy {
  public readonly client: Redis;

  constructor() {
    const host = process.env.REDIS_HOST || 'redis';
    const port = Number(process.env.REDIS_PORT || 6379);
    const password = process.env.REDIS_PASSWORD || undefined;

    this.client = new Redis({ host, port, password, lazyConnect: false });
  }

  async onModuleDestroy() {
    await this.client.quit();
  }
}
