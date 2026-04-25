import { BadRequestException, HttpException, HttpStatus, Injectable } from '@nestjs/common';
import crypto from 'crypto';
import { RedisService } from './redis.service';

function normalizePhone(phone: string) {
  const digits = phone.replace(/\D/g, '');
  if (digits.length === 11 && (digits.startsWith('7') || digits.startsWith('8'))) {
    return '7' + digits.substring(1);
  }
  if (digits.length === 10) return '7' + digits;
  if (digits.length === 11 && digits.startsWith('7')) return digits;
  throw new BadRequestException('Invalid phone');
}

function random4() {
  return Math.floor(1000 + Math.random() * 9000).toString();
}

function sha256(s: string) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

@Injectable()
export class OtpService {
  constructor(private readonly redis: RedisService) {}

  private cooldownKey(phone: string) {
    return `otp:cooldown:${phone}`;
  }
  private codeKey(phone: string) {
    return `otp:code:${phone}`;
  }
  private attemptsKey(phone: string) {
    return `otp:attempts:${phone}`;
  }

  async rollback(phone: string) {
    await this.redis.client.del(this.codeKey(phone));
    await this.redis.client.del(this.attemptsKey(phone));
    await this.redis.client.del(this.cooldownKey(phone));
  }

  async requestOtp(rawPhone: string) {
    const phone = normalizePhone(rawPhone);

    const cooldownSec = Number(process.env.OTP_COOLDOWN_SEC || 60);
    const ttlSec = Number(process.env.OTP_TTL_SEC || 300);

    const cooldownKey = this.cooldownKey(phone);
    const codeKey = this.codeKey(phone);
    const attemptsKey = this.attemptsKey(phone);

    const cooldown = await this.redis.client.ttl(cooldownKey);
    if (cooldown > 0) {
      throw new HttpException(`Cooldown ${cooldown}s`, HttpStatus.TOO_MANY_REQUESTS);
    }

    const code = random4();
    const pepper = process.env.JWT_SECRET || 'pepper';
    const hash = sha256(`${phone}:${code}:${pepper}`);

    await this.redis.client.set(cooldownKey, '1', 'EX', cooldownSec);
    await this.redis.client.set(codeKey, hash, 'EX', ttlSec);
    await this.redis.client.del(attemptsKey);

    return { phone, code, ttlSec };
  }

  async verifyOtp(rawPhone: string, code: string) {
    const phone = normalizePhone(rawPhone);
    const codeNorm = (code || '').replace(/\D/g, '');
    if (codeNorm.length !== 4) throw new BadRequestException('Invalid code');

    const attemptsKey = this.attemptsKey(phone);
    const codeKey = this.codeKey(phone);

    const maxAttempts = Number(process.env.OTP_MAX_ATTEMPTS || 5);

    const attempts = await this.redis.client.incr(attemptsKey);
    if (attempts === 1) {
      await this.redis.client.expire(attemptsKey, Number(process.env.OTP_TTL_SEC || 300));
    }
    if (attempts > maxAttempts) {
      throw new HttpException('Too many attempts', HttpStatus.TOO_MANY_REQUESTS);
    }

    const stored = await this.redis.client.get(codeKey);
    if (!stored) throw new BadRequestException('Code expired');

    const pepper = process.env.JWT_SECRET || 'pepper';
    const hash = sha256(`${phone}:${codeNorm}:${pepper}`);

    if (hash !== stored) throw new BadRequestException('Wrong code');

    await this.redis.client.del(codeKey);
    await this.redis.client.del(attemptsKey);

    return { phone };
  }
}
