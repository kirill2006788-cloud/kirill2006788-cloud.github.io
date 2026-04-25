import { Controller, Get } from '@nestjs/common';
import { RedisService } from './redis.service';

@Controller('tariffs')
export class TariffsController {
  constructor(private readonly redis: RedisService) {}

  @Get()
  async list() {
    const raw = await this.redis.client.get('tariffs:list');
    if (raw) {
      return { ok: true, tariffs: JSON.parse(raw) };
    }
    const tariffs = [
      {
        name: 'Трезвый водитель',
        mode: 'system',
        base: 2500,
        perMin: 25,
        perKm: 50,
        includedMin: 60,
        commission: 33.3,
        saturdayMarkupPercent: 0,
        sundayMarkupPercent: 0,
      },
      {
        name: 'Личный водитель',
        mode: 'system',
        base: 9000,
        perMin: 25,
        includedMin: 300,
        commission: 33.3,
        saturdayMarkupPercent: 0,
        sundayMarkupPercent: 0,
      },
      {
        name: 'Перегон автомобиля',
        mode: 'system',
        base: 2500,
        perMin: 25,
        perKm: 50,
        includedMin: 60,
        commission: 33.3,
        saturdayMarkupPercent: 0,
        sundayMarkupPercent: 0,
      },
    ];
    return { ok: true, tariffs };
  }
}
