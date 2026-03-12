import { Injectable } from '@nestjs/common';
import { RedisService } from './redis.service';

export type DriverStatus = 'online' | 'offline' | 'busy';

@Injectable()
export class DriversService {
  constructor(private readonly redis: RedisService) {}

  private geoKey() {
    return 'drivers:geo';
  }

  private statusKey() {
    return 'drivers:status';
  }

  private allKey() {
    return 'drivers:all';
  }

  private onlineKey(phone: string) {
    return `driver:online:${phone}`;
  }

  private locKey(phone: string) {
    return `driver:loc:${phone}`;
  }

  private profileKey(phone: string) {
    return `driver:profile:${phone}`;
  }

  private bonusKey(phone: string) {
    return `driver:bonus:${phone}`;
  }

  private ratingKey(phone: string) {
    return `driver:rating:${phone}`;
  }

  private blockKey(phone: string) {
    return `driver:block:${phone}`;
  }

  private blockMetaKey(phone: string) {
    return `driver:block_meta:${phone}`;
  }

  private missedOrdersKey(phone: string) {
    return `driver:missed_orders:${phone}`;
  }

  private subscriptionPaidUntilKey(phone: string) {
    return `driver:sub:paid_until:${phone}`;
  }

  private subscriptionSettingsKey() {
    return 'settings:subscription';
  }

  async getSubscriptionSettings(): Promise<{ amount: number; dayOfMonth: number }> {
    const raw = await this.redis.client.get(this.subscriptionSettingsKey());
    if (raw) {
      try {
        const o = JSON.parse(raw) as { amount?: number; dayOfMonth?: number };
        const amount = Number.isFinite(Number(o?.amount)) ? Math.max(0, Math.round(Number(o.amount))) : 1500;
        const day = Number.isFinite(Number(o?.dayOfMonth)) ? Math.max(1, Math.min(28, Math.round(Number(o.dayOfMonth)))) : 5;
        return { amount, dayOfMonth: day };
      } catch {
        return { amount: 1500, dayOfMonth: 5 };
      }
    }
    return { amount: 1500, dayOfMonth: 5 };
  }

  async setSubscriptionSettings(amount: number, dayOfMonth: number) {
    await this.redis.client.set(
      this.subscriptionSettingsKey(),
      JSON.stringify({
        amount: Math.max(0, Math.round(amount)),
        dayOfMonth: Math.max(1, Math.min(28, Math.round(dayOfMonth))),
      }),
    );
  }

  getNextDueDate(dayOfMonth: number): string {
    const now = new Date();
    let d = new Date(now.getFullYear(), now.getMonth(), dayOfMonth);
    if (d <= now) d = new Date(now.getFullYear(), now.getMonth() + 1, dayOfMonth);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  getCurrentPeriodDueDate(dayOfMonth: number): string {
    const now = new Date();
    const d = new Date(now.getFullYear(), now.getMonth(), dayOfMonth);
    if (d > now) {
      const prev = new Date(now.getFullYear(), now.getMonth() - 1, dayOfMonth);
      const y = prev.getFullYear();
      const m = String(prev.getMonth() + 1).padStart(2, '0');
      const day = String(prev.getDate()).padStart(2, '0');
      return `${y}-${m}-${day}`;
    }
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  async getSubscriptionPaidUntil(phone: string): Promise<string | null> {
    const raw = await this.redis.client.get(this.subscriptionPaidUntilKey(phone));
    return raw && /^\d{4}-\d{2}-\d{2}$/.test(raw) ? raw : null;
  }

  async setSubscriptionPaidUntil(phone: string, dateStr: string) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) return;
    await this.redis.client.set(this.subscriptionPaidUntilKey(phone), dateStr);
  }

  async isSubscriptionOverdue(phone: string): Promise<boolean> {
    const settings = await this.getSubscriptionSettings();
    const due = this.getCurrentPeriodDueDate(settings.dayOfMonth);
    const paidUntil = await this.getSubscriptionPaidUntil(phone);
    if (!paidUntil) return true;
    return paidUntil < due;
  }

  async setStatus(phone: string, status: DriverStatus) {
    await this.redis.client.hset(this.statusKey(), phone, status);
    await this.redis.client.sadd(this.allKey(), phone);
    if (status === 'online') {
      await this.redis.client.set(this.onlineKey(phone), '1', 'EX', 120);
    }
    if (status === 'offline' || status === 'busy') {
      await this.redis.client.del(this.onlineKey(phone));
    }
  }

  async updateLocation(phone: string, lat: number, lng: number) {
    await this.redis.client.geoadd(this.geoKey(), lng, lat, phone);
    await this.redis.client.set(
      this.locKey(phone),
      JSON.stringify({ lat, lng, updatedAt: new Date().toISOString() }),
      'EX',
      120,
    );
    // Не перезаписываем статус busy — только обновляем online-ключ если водитель online
    const currentStatus = await this.redis.client.hget(this.statusKey(), phone);
    if (currentStatus !== 'busy') {
      await this.redis.client.set(this.onlineKey(phone), '1', 'EX', 120);
      await this.redis.client.hset(this.statusKey(), phone, 'online');
    }
    await this.redis.client.sadd(this.allKey(), phone);
  }

  async getNearbyDrivers(lat: number, lng: number, radiusMeters: number, limit = 100) {
    const phones = await this.redis.client.georadius(
      this.geoKey(),
      lng,
      lat,
      radiusMeters,
      'm',
      'WITHDIST',
      'ASC',
      'COUNT',
      limit,
    );
    if (!phones.length) return [];

    const onlyPhones = (phones as Array<[string, string]>).map((p: [string, string]) => p[0]);
    const pipeline = this.redis.client.pipeline();
    onlyPhones.forEach((p) => pipeline.exists(this.onlineKey(p)));
    onlyPhones.forEach((p) => pipeline.exists(this.blockKey(p)));
    const results = await pipeline.exec();
    const online = new Set<string>();
    results?.slice(0, onlyPhones.length).forEach(([, res], idx) => {
      if (res === 1) online.add(onlyPhones[idx]);
    });
    const blocked = new Set<string>();
    results?.slice(onlyPhones.length).forEach(([, res], idx) => {
      if (res === 1) blocked.add(onlyPhones[idx]);
    });
    return onlyPhones.filter((p) => online.has(p) && !blocked.has(p));
  }

  async listOnlineDrivers() {
    const phones = await this.redis.client.smembers(this.allKey());
    if (!phones.length) return [];
    const pipeline = this.redis.client.pipeline();
    phones.forEach((p) => pipeline.exists(this.onlineKey(p)));
    phones.forEach((p) => pipeline.exists(this.blockKey(p)));
    const results = await pipeline.exec();
    const online = new Set<string>();
    results?.slice(0, phones.length).forEach(([, res], idx) => {
      if (res === 1) online.add(phones[idx]);
    });
    const blocked = new Set<string>();
    results?.slice(phones.length).forEach(([, res], idx) => {
      if (res === 1) blocked.add(phones[idx]);
    });
    return phones.filter((p) => online.has(p) && !blocked.has(p));
  }

  async listDrivers() {
    const phones = await this.redis.client.smembers(this.allKey());
    if (!phones.length) return [];
    const pipeline = this.redis.client.pipeline();
    phones.forEach((p) => pipeline.hget(this.statusKey(), p));
    phones.forEach((p) => pipeline.get(this.locKey(p)));
    phones.forEach((p) => pipeline.exists(this.blockKey(p)));
    phones.forEach((p) => pipeline.get(this.blockMetaKey(p)));
    const results = await pipeline.exec();
    const statuses = results?.slice(0, phones.length).map((r) => r?.[1]) || [];
    const locs = results?.slice(phones.length, phones.length * 2).map((r) => r?.[1]) || [];
    const blocks = results?.slice(phones.length * 2, phones.length * 3).map((r) => r?.[1]) || [];
    const blockMetas = results?.slice(phones.length * 3).map((r) => r?.[1]) || [];
    return phones.map((phone, idx) => {
      const locRaw = typeof locs[idx] === 'string' ? locs[idx] : null;
      const blockMetaRaw = typeof blockMetas[idx] === 'string' ? blockMetas[idx] : null;
      let blockMeta: any = null;
      try { if (blockMetaRaw) blockMeta = JSON.parse(blockMetaRaw); } catch { blockMeta = null; }
      return {
        phone,
        status: (statuses[idx] as DriverStatus) || 'offline',
        location: locRaw ? JSON.parse(locRaw) : null,
        blocked: blocks[idx] === 1,
        blockReason: blockMeta?.reason || null,
        blockUntil: blockMeta?.until || null,
      };
    });
  }

  async isBlocked(phone: string): Promise<boolean> {
    const val = await this.redis.client.exists(this.blockKey(phone));
    return val === 1;
  }

  async getBlockMeta(phone: string): Promise<{ reason?: string; until?: string | null } | null> {
    const raw = await this.redis.client.get(this.blockMetaKey(phone));
    if (!raw) return null;
    try {
      const meta = JSON.parse(raw) as { reason?: string; until?: string | null };
      return {
        reason: typeof meta.reason === 'string' ? meta.reason : undefined,
        until: typeof meta.until === 'string' ? meta.until : null,
      };
    } catch {
      return null;
    }
  }

  async blockTemporarily(phone: string, reason: string, hours: number) {
    const ttlSec = Math.max(60, Math.round(hours * 60 * 60));
    const until = new Date(Date.now() + ttlSec * 1000).toISOString();
    await this.redis.client.set(this.blockKey(phone), '1', 'EX', ttlSec);
    await this.redis.client.set(
      this.blockMetaKey(phone),
      JSON.stringify({ reason, until }),
      'EX',
      ttlSec,
    );
    await this.setStatus(phone, 'offline');
  }

  async clearBlock(phone: string) {
    await this.redis.client.del(this.blockKey(phone));
    await this.redis.client.del(this.blockMetaKey(phone));
    await this.redis.client.del(this.missedOrdersKey(phone));
  }

  async registerMissedOrder(phone: string): Promise<{ count: number; blocked: boolean; until?: string }> {
    const key = this.missedOrdersKey(phone);
    const count = await this.redis.client.incr(key);
    await this.redis.client.expire(key, 60 * 60 * 48);
    if (count >= 3) {
      await this.blockTemporarily(phone, 'missed_orders', 48);
      await this.redis.client.del(key);
      const meta = await this.getBlockMeta(phone);
      return { count, blocked: true, until: meta?.until || undefined };
    }
    return { count, blocked: false };
  }

  async getProfile(phone: string) {
    const raw = await this.redis.client.get(this.profileKey(phone));
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  }

  async saveProfile(phone: string, profile: Record<string, unknown>) {
    await this.redis.client.set(this.profileKey(phone), JSON.stringify(profile));
    await this.redis.client.sadd(this.allKey(), phone);
  }

  /** Гарантируем, что водитель есть в drivers:all (вызывается при OTP-входе) */
  async ensureRegistered(phone: string) {
    await this.redis.client.sadd(this.allKey(), phone);
  }

  async getBonus(phone: string) {
    const raw = await this.redis.client.hgetall(this.bonusKey(phone));
    const available = Number(raw.available || 0);
    const earned = Number(raw.earned || 0);
    return { available, earned };
  }

  async getRating(phone: string) {
    const raw = await this.redis.client.hgetall(this.ratingKey(phone));
    const avg = Number(raw.avg || 0);
    const count = Number(raw.count || 0);
    return { avg, count };
  }

  async addBonus(phone: string, amount: number) {
    const value = Math.max(0, Math.round(Number(amount) || 0));
    if (value <= 0) return;
    const key = this.bonusKey(phone);
    const multi = this.redis.client.multi();
    multi.hincrby(key, 'available', value);
    multi.hincrby(key, 'earned', value);
    await multi.exec();
  }

  /** O(1) проверка наличия активного заказа у водителя через Redis SET */
  async hasActiveOrder(phone: string): Promise<boolean> {
    const val = await this.redis.client.sismember('drivers:active_order', phone);
    return val === 1;
  }

  async getLocation(phone: string): Promise<{ lat: number; lng: number } | null> {
    const raw = await this.redis.client.get(this.locKey(phone));
    if (!raw) return null;
    try {
      const loc = JSON.parse(raw) as { lat?: number; lng?: number };
      if (!Number.isFinite(loc.lat) || !Number.isFinite(loc.lng)) return null;
      return { lat: Number(loc.lat), lng: Number(loc.lng) };
    } catch {
      return null;
    }
  }
}
