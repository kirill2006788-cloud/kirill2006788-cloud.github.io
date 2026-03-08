import { Injectable } from '@nestjs/common';
import axios from 'axios';

@Injectable()
export class SmsService {
  async sendOtp(phone: string, code: string) {
    if (process.env.OTP_DEBUG_LOG === '1') {
      process.stdout.write(`OTP_DEBUG_LOG=1. OTP for ${phone}: ${code}\n`);
      return;
    }

    const login = process.env.SMSC_LOGIN;
    const psw = process.env.SMSC_PASSWORD;

    const message = `Код: ${code}`;

    if (!login || !psw) {
      if (process.env.NODE_ENV === 'production') {
        throw new Error('SMSC not configured in production');
      }
      process.stdout.write('SMSC not configured. Skipping SMS send in non-production mode.\n');
      return;
    }

    try {
      const params = new URLSearchParams({
        login,
        psw,
        phones: phone,
        mes: message,
        fmt: '3',
      });
      const res = await axios.get(`https://smsc.ru/sys/send.php?${params.toString()}`, {
        timeout: 20_000,
      });
      if (res.status < 200 || res.status >= 300) {
        process.stdout.write(`SMSC response status ${res.status}: ${JSON.stringify(res.data)}\n`);
        throw new Error(`SMSC status ${res.status}`);
      }
      if (typeof res.data === 'string') {
        process.stdout.write(`SMSC response: ${res.data}\n`);
      } else {
        process.stdout.write(`SMSC response: ${JSON.stringify(res.data)}\n`);
      }
    } catch (err: any) {
      const status = err?.response?.status;
      const data = err?.response?.data;
      process.stdout.write(`SMSC error: ${err?.message || err}\n`);
      if (status) process.stdout.write(`SMSC status: ${status}\n`);
      if (data) process.stdout.write(`SMSC data: ${JSON.stringify(data)}\n`);
      throw err;
    }
  }
}
