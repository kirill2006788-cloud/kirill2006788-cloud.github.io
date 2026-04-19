import { BadRequestException, Body, ConflictException, Controller, ForbiddenException, Get, Headers, Post, Query, TooManyRequestsException, UnauthorizedException } from '@nestjs/common';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import { RedisService } from './redis.service';

const REFERRAL_CODE_LENGTH = 8;
const REFERRAL_CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // без 0,O,1,I

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

  private referralCodeLookupKey(code: string) {
    return `referral:code:${code.toUpperCase()}`;
  }

  private promoKey(code: string) {
    return `promo:${code.toLowerCase()}`;
  }

  private promoUsedKey(clientId: string, code: string) {
    return `client:promo_used:${clientId}:${code.toLowerCase()}`;
  }

  private promoActivateRateKey(clientId: string) {
    return `client:promo_rate:${clientId}`;
  }

  private referralApplyLockKey(clientId: string) {
    return `client:referral_lock:${clientId}`;
  }

  private pushTokenKey(clientId: string) {
    return `client:push_token:${clientId}`;
  }

  private requireClientId(auth?: string) {
    const token = auth?.replace(/^Bearer\s+/i, '').trim();
    if (!token) throw new UnauthorizedException('Client token required');
    const secret = process.env.JWT_SECRET;
    if (!secret) throw new UnauthorizedException('Server configuration error');
    let payload: any;
    try {
      payload = jwt.verify(token, secret) as any;
    } catch {
      throw new UnauthorizedException('Invalid token');
    }
    if (!payload || payload.role !== 'client' || typeof payload.phone !== 'string' || !payload.phone.trim()) {
      throw new UnauthorizedException('Client token required');
    }
    return payload.phone.trim();
  }

  private async generateUniqueReferralCode(): Promise<string> {
    for (let attempt = 0; attempt < 20; attempt++) {
      let code = '';
      const bytes = crypto.randomBytes(REFERRAL_CODE_LENGTH);
      for (let i = 0; i < REFERRAL_CODE_LENGTH; i++) {
        code += REFERRAL_CODE_CHARS[bytes[i]! % REFERRAL_CODE_CHARS.length];
      }
      const key = this.referralCodeLookupKey(code);
      const existing = await this.redis.client.get(key);
      if (!existing) return code;
    }
    return crypto.randomBytes(REFERRAL_CODE_LENGTH).toString('base64url').slice(0, REFERRAL_CODE_LENGTH).toUpperCase().replace(/[^A-Z0-9]/g, 'A');
  }

  @Get('profile')
  async getProfile(@Query('clientId') clientId?: string, @Headers('authorization') auth?: string) {
    const id = this.requireClientId(auth);
    if (clientId && clientId.trim() && clientId.trim() !== id) {
      throw new ForbiddenException('Client token mismatch');
    }
    const raw = await this.redis.client.get(this.profileKey(id));
    let profile: any = {};
    try { if (raw) profile = JSON.parse(raw); } catch { /* corrupted profile data */ }
    const referralRaw = await this.redis.client.hgetall(this.referralKey(id));
    let myCode = referralRaw.code || profile.myReferralCode;
    if (!myCode || typeof myCode !== 'string' || myCode.length < 4) {
      myCode = await this.generateUniqueReferralCode();
      await this.redis.client.set(this.referralCodeLookupKey(myCode), id);
      await this.redis.client.hset(this.referralKey(id), 'code', myCode);
      profile.myReferralCode = myCode;
      profile.updatedAt = new Date().toISOString();
      await this.redis.client.set(this.profileKey(id), JSON.stringify(profile));
    }
    const bonusRaw = await this.redis.client.hgetall(this.bonusKey(id));
    const bonus = {
      available: Number(bonusRaw.available || 0),
      earned: Number(bonusRaw.earned || 0),
    };
    const referral = {
      count: Number(referralRaw.count || 0),
      code: myCode,
    };
    return { ok: true, profile, bonus, referral };
  }

  @Post('profile')
  async saveProfile(
    @Headers('authorization') auth: string,
    @Body()
    body: {
      clientId?: string;
      fullName?: string;
      phone?: string;
      referralCode?: string;
    },
  ) {
    const id = this.requireClientId(auth);
    if (body.clientId && body.clientId.trim() && body.clientId.trim() !== id) {
      throw new ForbiddenException('Client token mismatch');
    }

    const referralCodeInput = (body.referralCode || '').toString().trim();
    const existingRaw = await this.redis.client.get(this.profileKey(id));
    let existing: any = {};
    try { if (existingRaw) existing = JSON.parse(existingRaw); } catch { /* corrupted */ }

    // Обработка реферального кода: ищем владельца кода (уникальный код или номер телефона)
    if (referralCodeInput && !existing.usedReferralCode) {
      const lockKey = this.referralApplyLockKey(id);
      const lockOk = await (this.redis.client as any).set(lockKey, '1', 'EX', 8, 'NX');
      if (!lockOk) {
        throw new ConflictException('Referral update already in progress, retry');
      }
      try {
        const latestRaw = await this.redis.client.get(this.profileKey(id));
        let latest: any = {};
        try { if (latestRaw) latest = JSON.parse(latestRaw); } catch { latest = {}; }

        if (!latest.usedReferralCode) {
          let referrerId: string | null = null;
          const codeUpper = referralCodeInput.toUpperCase().replace(/\s/g, '');
          const digitsOnly = referralCodeInput.replace(/\D/g, '');
          if (codeUpper.length >= 4 && codeUpper.length <= 12) {
            const byCode = await this.redis.client.get(this.referralCodeLookupKey(codeUpper));
            if (byCode) referrerId = byCode;
          }
          if (!referrerId && digitsOnly.length >= 10 && digitsOnly.length <= 11) {
            referrerId = digitsOnly.startsWith('7') ? digitsOnly : `7${digitsOnly}`;
          }
          if (referrerId) {
            const idNorm = id.replace(/\D/g, '');
            const referrerNorm = referrerId.replace(/\D/g, '');
            if (referrerNorm !== idNorm) {
              const refKey = this.referralKey(referrerId);
              const countRes = await this.redis.client.hincrby(refKey, 'count', 1);
              if (countRes % 3 === 0) {
                await this.redis.client.hincrby(this.bonusKey(referrerId), 'available', 500);
                await this.redis.client.hincrby(this.bonusKey(referrerId), 'earned', 500);
              }
              existing.usedReferralCode = referrerId;
            }
          }
        }
      } finally {
        await this.redis.client.del(lockKey);
      }
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

  @Post('push-token')
  async savePushToken(
    @Headers('authorization') auth?: string,
    @Body() body?: { token?: string; platform?: string },
  ) {
    const clientId = this.requireClientId(auth);
    const token = (body?.token || '').toString().trim();
    if (!token) {
      await this.redis.client.del(this.pushTokenKey(clientId));
      return { ok: true, deleted: true };
    }

    const payload = {
      token,
      platform: (body?.platform || 'ios').toString(),
      updatedAt: new Date().toISOString(),
    };
    await this.redis.client.set(this.pushTokenKey(clientId), JSON.stringify(payload));
    return { ok: true };
  }

  @Post('bonus/use')
  async useBonus(@Body() body: { clientId?: string; amount?: number }, @Headers('authorization') auth?: string) {
    const id = this.requireClientId(auth);
    const amount = Math.max(0, Math.round(Number(body.amount) || 0));
    if (body.clientId && body.clientId.trim() && body.clientId.trim() !== id) {
      throw new ForbiddenException('Client token mismatch');
    }
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
  async activatePromo(@Body() body: { clientId?: string; code?: string }, @Headers('authorization') auth?: string) {
    const id = this.requireClientId(auth);
    const code = (body.code || '').toString().trim().toLowerCase();
    if (body.clientId && body.clientId.trim() && body.clientId.trim() !== id) {
      throw new ForbiddenException('Client token mismatch');
    }
    if (!code) throw new BadRequestException('code required');
    if (!/^[a-z0-9_-]{4,32}$/i.test(code)) {
      throw new BadRequestException('invalid promo code format');
    }

    const rateKey = this.promoActivateRateKey(id);
    const attempt = await this.redis.client.incr(rateKey);
    if (attempt === 1) {
      await this.redis.client.expire(rateKey, 60);
    }
    if (attempt > 20) {
      throw new TooManyRequestsException('Too many promo activation attempts');
    }

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
    const reserved = await (this.redis.client as any).set(usedKey, '1', 'EX', 60 * 60 * 24 * 365 * 10, 'NX');
    if (!reserved) {
      throw new BadRequestException('Промокод уже был использован вами ранее');
    }

    const profileRaw = await this.redis.client.get(this.profileKey(id));
    let profile: any = {};
    try { if (profileRaw) profile = JSON.parse(profileRaw); } catch { /* corrupted */ }
    profile.promoCode = code;
    profile.promoDiscountPercent = discount;
    profile.updatedAt = new Date().toISOString();
    await this.redis.client.set(this.profileKey(id), JSON.stringify(profile));

    return { ok: true, code, discount };
  }
}
