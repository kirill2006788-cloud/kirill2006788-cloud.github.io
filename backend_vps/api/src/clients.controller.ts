import { BadRequestException, Body, Controller, Get, Post, Query } from '@nestjs/common';
import { RedisService } from './redis.service';

@Controller('client')
export class ClientsController {
  constructor(private readonly redis: RedisService) {}

  private profileKey(id: string) {
    return `client:profile:${id}`;
  }

  private bonusKey(id: string) {
    return `client:bonus:${id}`;
  }

  private referralKey(id: string) {
    return `client:referral:${id}`;
  }

  private promoKey(code: string) {
    return `promo:${code.toLowerCase()}`;
  }

  private promoUsedKey(clientId: string, code: string) {
    return `client:promo_used:${clientId}:${code.toLowerCase()}`;
  }

  @Get('profile')
  async getProfile(@Query('clientId') clientId?: string) {
    const id = (clientId || '').trim();
    if (!id) throw new BadRequestException('clientId required');
    const raw = await this.redis.client.get(this.profileKey(id));
    let profile: any = {};
    try { if (raw) profile = JSON.parse(raw); } catch { /* corrupted profile data */ }
    const bonusRaw = await this.redis.client.hgetall(this.bonusKey(id));
    const referralRaw = await this.redis.client.hgetall(this.referralKey(id));
    const bonus = {
      available: Number(bonusRaw.available || 0),
      earned: Number(bonusRaw.earned || 0),
    };
    const referral = {
      count: Number(referralRaw.count || 0),
      code: referralRaw.code || id.replace(/\D/g, ''),
    };
    return { ok: true, profile, bonus, referral };
  }

  @Post('profile')
  async saveProfile(
    @Body()
    body: {
      clientId?: string;
      fullName?: string;
      phone?: string;
      referralCode?: string;
    },
  ) {
    const id = (body.clientId || '').trim();
    if (!id) throw new BadRequestException('clientId required');

    const referralCode = (body.referralCode || '').toString().trim().replace(/\D/g, '');
    const existingRaw = await this.redis.client.get(this.profileKey(id));
    let existing: any = {};
    try { if (existingRaw) existing = JSON.parse(existingRaw); } catch { /* corrupted */ }

    // Обработка реферального кода
    if (referralCode && referralCode !== id.replace(/\D/g, '') && !existing.usedReferralCode) {
      // Увеличиваем счётчик приглашений для владельца кода
      const refKey = this.referralKey(referralCode);
      const countRes = await this.redis.client.hincrby(refKey, 'count', 1);
      // Если кратно 3 - начисляем бонус
      if (countRes % 3 === 0) {
        await this.redis.client.hincrby(this.bonusKey(referralCode), 'available', 500);
        await this.redis.client.hincrby(this.bonusKey(referralCode), 'earned', 500);
      }
      existing.usedReferralCode = referralCode;
    }

    const profile = {
      ...existing,
      clientId: id,
      fullName: body.fullName?.toString() || existing.fullName || '',
      phone: body.phone?.toString() || existing.phone || '',
      updatedAt: new Date().toISOString(),
    };

    await this.redis.client.set(this.profileKey(id), JSON.stringify(profile));
    await this.redis.client.sadd('clients:all', id);

    return { ok: true, profile };
  }

  @Post('bonus/use')
  async useBonus(@Body() body: { clientId?: string; amount?: number }) {
    const id = (body.clientId || '').trim();
    const amount = Math.max(0, Math.round(Number(body.amount) || 0));
    if (!id) throw new BadRequestException('clientId required');
    if (amount <= 0) throw new BadRequestException('amount must be positive');

    const key = this.bonusKey(id);
    const available = Number((await this.redis.client.hget(key, 'available')) || 0);
    if (amount > available) {
      throw new BadRequestException('Insufficient bonus balance');
    }
    await this.redis.client.hincrby(key, 'available', -amount);
    const newAvailable = Math.max(0, available - amount);
    return { ok: true, used: amount, available: newAvailable };
  }

  @Post('promo/activate')
  async activatePromo(@Body() body: { clientId?: string; code?: string }) {
    const id = (body.clientId || '').trim();
    const code = (body.code || '').toString().trim().toLowerCase();
    if (!id) throw new BadRequestException('clientId required');
    if (!code) throw new BadRequestException('code required');

    const promoRaw = await this.redis.client.hgetall(this.promoKey(code));
    if (!promoRaw || Object.keys(promoRaw).length === 0) {
      throw new BadRequestException('promo not found');
    }
    const active = promoRaw.active !== 'false';
    const discount = Math.max(0, Math.min(90, Number(promoRaw.discount || 0)));
    const expiresAt = promoRaw.expiresAt ? Date.parse(promoRaw.expiresAt) : NaN;
    if (!active || discount <= 0) {
      throw new BadRequestException('promo inactive');
    }
    if (!Number.isNaN(expiresAt) && Date.now() > expiresAt) {
      throw new BadRequestException('promo expired');
    }

    const usedKey = this.promoUsedKey(id, code);
    const alreadyUsed = await this.redis.client.get(usedKey);
    if (alreadyUsed) {
      throw new BadRequestException('Промокод уже был использован вами ранее');
    }

    const profileRaw = await this.redis.client.get(this.profileKey(id));
    let profile: any = {};
    try { if (profileRaw) profile = JSON.parse(profileRaw); } catch { /* corrupted */ }
    profile.promoCode = code;
    profile.promoDiscountPercent = discount;
    profile.updatedAt = new Date().toISOString();
    await this.redis.client.set(this.profileKey(id), JSON.stringify(profile));
    await this.redis.client.set(usedKey, '1', 'EX', 60 * 60 * 24 * 365 * 10);

    return { ok: true, code, discount };
  }
}
