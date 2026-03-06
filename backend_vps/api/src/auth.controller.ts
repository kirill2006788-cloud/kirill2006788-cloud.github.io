import { BadGatewayException, BadRequestException, Body, Controller, Post, UnauthorizedException } from '@nestjs/common';
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
  async adminLogin(@Body() body: { login?: string; password?: string }) {
    const login = (body.login || '').trim();
    const password = (body.password || '').trim();
    const expectedLogin = (process.env.ADMIN_LOGIN || '').trim();
    const expectedPassword = (process.env.ADMIN_PASSWORD || '').trim();
    if (!expectedLogin || !expectedPassword) {
      throw new UnauthorizedException('Admin login not configured');
    }
    if (login !== expectedLogin || password !== expectedPassword) {
      throw new UnauthorizedException('Invalid credentials');
    }
    const secret = process.env.JWT_SECRET;
    if (!secret) throw new UnauthorizedException('Server configuration error');
    const token = jwt.sign({ role: 'admin', login }, secret, { expiresIn: '30d' });
    return { ok: true, token };
  }
}
