import { Injectable } from '@nestjs/common';
import axios from 'axios';

@Injectable()
export class SmsService {
  async sendOtp(phone: string, code: string) {
    if (process.env.OTP_DEBUG_LOG === '1') {
      process.stdout.write(`OTP_DEBUG_LOG=1. OTP for ${phone}: ${code}\n`);
      return;
    }

    const message = `Ваш код для входа в Трезвый водитель: ${code}`;
    const provider = (process.env.SMS_PROVIDER || 'smsaero').toLowerCase();

    if (provider === 'smsaero') {
      await this.sendViaSmsAero(phone, message);
    } else {
      await this.sendViaSmsc(phone, message);
    }
  }

  private async sendViaSmsAero(phone: string, message: string) {
    const email = process.env.SMSAERO_EMAIL;
    const apiKey = process.env.SMSAERO_API_KEY;

    if (!email || !apiKey) {
      if (process.env.NODE_ENV === 'production') {
        throw new Error('SMS Aero not configured in production');
      }
      process.stdout.write('SMS Aero not configured. Skipping SMS send.\n');
      return;
    }

    const digits = phone.replace(/\D/g, '');
    const authHeader = 'Basic ' + Buffer.from(`${email}:${apiKey}`).toString('base64');

    try {
      const protocol = process.env.SMSAERO_USE_HTTP === '1' ? 'http' : 'https';
      const res = await axios.get(
        `${protocol}://gate.smsaero.ru/v2/sms/send`,
        {
          params: { number: digits, text: message, sign: 'SMS Aero' },
          headers: { Authorization: authHeader },
          timeout: 20_000,
        },
      );
      process.stdout.write(`SmsAero response: ${JSON.stringify(res.data)}\n`);
      if (!res.data?.success) {
        throw new Error(`SmsAero error: ${JSON.stringify(res.data)}`);
      }
    } catch (err: any) {
      process.stdout.write(`SmsAero error: ${err?.message || err}\n`);
      if (err?.response?.data) {
        process.stdout.write(`SmsAero data: ${JSON.stringify(err.response.data)}\n`);
      }
      throw err;
    }
  }

  private async sendViaSmsc(phone: string, message: string) {
    const login = process.env.SMSC_LOGIN;
    const psw = process.env.SMSC_PASSWORD;

    if (!login || !psw) {
      if (process.env.NODE_ENV === 'production') {
        throw new Error('SMSC not configured in production');
      }
      process.stdout.write('SMSC not configured. Skipping SMS send.\n');
      return;
    }

    try {
      const params = new URLSearchParams({
        login, psw, phones: phone, mes: message, fmt: '3',
      });
      const res = await axios.get(`https://smsc.ru/sys/send.php?${params.toString()}`, {
        timeout: 20_000,
      });
      if (res.status < 200 || res.status >= 300) {
        throw new Error(`SMSC status ${res.status}`);
      }
      process.stdout.write(`SMSC response: ${JSON.stringify(res.data)}\n`);
    } catch (err: any) {
      process.stdout.write(`SMSC error: ${err?.message || err}\n`);
      throw err;
    }
  }
}
