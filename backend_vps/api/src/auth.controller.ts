import { BadGatewayException, BadRequestException, Body, Controller, Headers, Post, UnauthorizedException } from '@nestjs/common';
import { createHash, randomUUID, timingSafeEqual } from 'crypto';
import jwt from 'jsonwebtoken';
import { OtpService } from './otp.service';
import { SmsService } from './sms.service';
import { DriversService } from './drivers.service';

@Controller('auth/otp')
export class AuthController {
  constructor(
    private readonly otp: OtpService,
    private readonly sms: SmsService,
    private readonly drivers: DriversService,
  ) {}

  private static adminLoginAttempts = new Map<string, { count: number; firstAt: number; lockUntil?: number }>();

  private getClientIp(forwardedFor?: string, realIp?: string) {
    const forwarded = (forwardedFor || '').toString().split(',')[0].trim();
    const direct = (realIp || '').toString().trim();
    return (forwarded || direct || 'unknown').slice(0, 80);
  }

  private isAdminIpAllowed(ip: string) {
    const raw = (process.env.ADMIN_IP_ALLOWLIST || process.env.ADMIN_ALLOWED_IPS || '').trim();
    if (!raw) return true;
    const normalized = ip.trim().toLowerCase();
    if (!normalized || normalized === 'unknown') return false;
    const entries = raw
      .split(',')
      .map((item) => item.trim().toLowerCase())
      .filter(Boolean);
    return entries.some((entry) => {
      if (entry === normalized) return true;
      if (entry.endsWith('*')) {
        return normalized.startsWith(entry.slice(0, -1));
      }
      return false;
    });
  }

  private safeEqual(left: string, right: string) {
    const leftHash = createHash('sha256').update(left).digest();
    const rightHash = createHash('sha256').update(right).digest();
    return timingSafeEqual(leftHash, rightHash);
  }

  private guardAdminLogin(ip: string) {
    const now = Date.now();
    const windowMs = Number(process.env.ADMIN_LOGIN_WINDOW_MS || 10 * 60 * 1000);
    const rec = AuthController.adminLoginAttempts.get(ip);
    if (rec?.lockUntil && rec.lockUntil > now) {
      throw new UnauthorizedException('Too many attempts. Try later.');
    }
    if (!rec || now - rec.firstAt > windowMs) {
      AuthController.adminLoginAttempts.set(ip, { count: 0, firstAt: now });
      return;
    }
  }

  private failAdminLogin(ip: string) {
    const now = Date.now();
    const maxAttempts = Number(process.env.ADMIN_LOGIN_MAX_ATTEMPTS || 8);
    const lockMs = Number(process.env.ADMIN_LOGIN_LOCK_MS || 10 * 60 * 1000);
    const rec = AuthController.adminLoginAttempts.get(ip) || { count: 0, firstAt: now };
    rec.count += 1;
    if (rec.count >= maxAttempts) {
      rec.lockUntil = now + lockMs;
      rec.count = 0;
      rec.firstAt = now;
    }
    AuthController.adminLoginAttempts.set(ip, rec);
  }

  private clearAdminLoginAttempts(ip: string) {
    AuthController.adminLoginAttempts.delete(ip);
  }

  @Post('request')
  async request(@Body() body: { phone: string }) {
    if (!body?.phone || typeof body.phone !== 'string' || body.phone.trim().length < 10) {
      throw new BadRequestException('Invalid phone');
    }
    const { phone, code, ttlSec } = await this.otp.requestOtp(body.phone);

    try {
      await this.sms.sendOtp(phone, code);
    } catch (e) {
      await this.otp.rollback(phone);
      throw new BadGatewayException('SMS provider timeout/unavailable');
    }

    return { ok: true, ttlSec };
  }

  @Post('verify')
  async verify(@Body() body: { phone: string; code: string; role?: 'client' | 'driver' }) {
    if (!body?.phone || typeof body.phone !== 'string' || body.phone.trim().length < 10) {
      throw new BadRequestException('Invalid phone');
    }
    if (!body?.code || typeof body.code !== 'string') {
      throw new BadRequestException('Invalid code');
    }
    const { phone } = await this.otp.verifyOtp(body.phone, body.code);
    const role = body.role === 'driver' ? 'driver' : 'client';

    const secret = process.env.JWT_SECRET;
    if (!secret) throw new UnauthorizedException('Server configuration error');

    const token = jwt.sign({ phone, role }, secret, { expiresIn: '30d' });

    // При входе водителя — добавляем в drivers:all, чтобы он был виден в админке
    if (role === 'driver') {
      await this.drivers.ensureRegistered(phone);
    }

    return { ok: true, token };
  }

  @Post('admin/login')
  async adminLogin(
    @Body() body: { login?: string; password?: string },
    @Headers('x-forwarded-for') forwardedFor?: string,
    @Headers('x-real-ip') realIp?: string,
  ) {
    const ip = this.getClientIp(forwardedFor, realIp);
    if (!this.isAdminIpAllowed(ip)) {
      throw new UnauthorizedException('Access denied');
    }
    this.guardAdminLogin(ip);
    const login = typeof body?.login === 'string' ? body.login.trim() : '';
    const password = typeof body?.password === 'string' ? body.password.trim() : '';
    const expectedLogin = (process.env.ADMIN_LOGIN || '').trim();
    const expectedPassword = (process.env.ADMIN_PASSWORD || '').trim();
    if (!expectedLogin || !expectedPassword) {
      throw new UnauthorizedException('Server configuration error');
    }
    if (expectedPassword.length < 12 && String(process.env.NODE_ENV || '').toLowerCase() === 'production') {
      throw new UnauthorizedException('Server configuration error');
    }
    if (!login || !password || !this.safeEqual(login, expectedLogin) || !this.safeEqual(password, expectedPassword)) {
      this.failAdminLogin(ip);
      throw new UnauthorizedException('Invalid credentials');
    }
    const secret = process.env.ADMIN_JWT_SECRET || process.env.JWT_SECRET;
    if (!secret) throw new UnauthorizedException('Server configuration error');
    const expiresIn = (process.env.ADMIN_JWT_EXPIRES_IN || '12h').trim();
    this.clearAdminLoginAttempts(ip);
    const token = jwt.sign(
      { role: 'admin', login, scope: 'admin:full' },
      secret,
      {
        expiresIn,
        issuer: 'prostotaxi-admin',
        audience: 'prostotaxi-admin-panel',
        jwtid: randomUUID(),
      },
    );
    return { ok: true, token, expiresIn };
  }
}
