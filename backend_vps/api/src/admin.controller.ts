import { Body, Controller, Get, Headers, Param, Post, Query, UnauthorizedException } from '@nestjs/common';
import { RedisService } from './redis.service';
import { DriversService } from './drivers.service';
import { OrdersService } from './orders.service';
import { EventsGateway } from './events.gateway';
import jwt from 'jsonwebtoken';

type DriverProfile = {
  phone: string;
  fullName?: string;
  email?: string;
  rating?: number;
  inn?: string;
  passport?: string;
  docsSigned?: boolean;
  registrationStatus?: string;
  referralCount?: number;
};

type ClientProfile = {
  id: string;
  fullName?: string;
  phone?: string;
  email?: string;
};

@Controller('admin')
export class AdminController {
  constructor(
    private readonly redis: RedisService,
    private readonly drivers: DriversService,
    private readonly orders: OrdersService,
    private readonly events: EventsGateway,
  ) {}

  private requireAdmin(authHeader?: string) {
    const token = authHeader?.replace(/^Bearer\s+/i, '').trim();
    if (!token) throw new UnauthorizedException('Admin token required');
    const secret = process.env.JWT_SECRET;
    if (!secret) throw new Error('JWT_SECRET not set');
    let payload: any;
    try {
      payload = jwt.verify(token, secret) as any;
    } catch {
      throw new UnauthorizedException('Invalid token');
    }
    if (!payload || payload.role !== 'admin') {
      throw new UnauthorizedException('Admin token required');
    }
    return payload;
  }

  private driverProfileKey(phone: string) {
    return `driver:profile:${phone}`;
  }

  private driverPhotosBackupKey(phone: string) {
    return `driver:photos_backup:${phone}`;
  }

  private clientProfileKey(id: string) {
    return `client:profile:${id}`;
  }

  private clientBlockKey(id: string) {
    return `client:block:${id}`;
  }

  private clientBlockMetaKey(id: string) {
    return `client:block_meta:${id}`;
  }

  private driversSet() {
    return 'drivers:all';
  }

  private driverStatusKey() {
    return 'drivers:status';
  }

  private driverGeoKey() {
    return 'drivers:geo';
  }

  private driverLocKey(phone: string) {
    return `driver:loc:${phone}`;
  }

  private driverPushTokenKey(phone: string) {
    return `driver:push_token:${phone}`;
  }

  private driverAdminCommentKey(phone: string) {
    return `driver:admin_comment:${phone}`;
  }

  private clientsSet() {
    return 'clients:all';
  }

  private clientAdminCommentKey(id: string) {
    return `client:admin_comment:${id}`;
  }

  private promoSet() {
    return 'promos:all';
  }

  private promoKey(code: string) {
    return `promo:${code.toLowerCase()}`;
  }

  private defaultTariffs() {
    return [
      { name: 'Трезвый водитель', mode: 'system', base: 2500, perMin: 25, perKm: 50, includedMin: 60, commission: 33.3, saturdayMarkupPercent: 0, sundayMarkupPercent: 0 },
      { name: 'Личный водитель', mode: 'system', base: 9000, perMin: 25, includedMin: 300, commission: 33.3, saturdayMarkupPercent: 0, sundayMarkupPercent: 0 },
      { name: 'Перегон автомобиля', mode: 'system', base: 2500, perMin: 25, perKm: 50, includedMin: 60, commission: 33.3, saturdayMarkupPercent: 0, sundayMarkupPercent: 0 },
    ];
  }

  private normalizeTariff(input: any, fallback: any) {
    const base = Number.isFinite(Number(input?.base)) ? Math.max(0, Math.round(Number(input.base))) : Number(fallback.base || 0);
    const perKm = Number.isFinite(Number(input?.perKm)) ? Math.max(0, Math.round(Number(input.perKm))) : Number(fallback.perKm || 0);
    const perMin = Number.isFinite(Number(input?.perMin)) ? Math.max(0, Math.round(Number(input.perMin))) : Number(fallback.perMin || 0);
    const includedMin = Number.isFinite(Number(input?.includedMin))
      ? Math.max(0, Math.round(Number(input.includedMin)))
      : Number(fallback.includedMin || 0);
    const commissionRaw = Number(input?.commission);
    const commission = Number.isFinite(commissionRaw)
      ? Math.max(0, Math.min(100, commissionRaw))
      : Number(fallback.commission || 0);
    const saturdayRaw = Number(input?.saturdayMarkupPercent);
    const saturdayMarkupPercent = Number.isFinite(saturdayRaw)
      ? Math.max(0, Math.min(300, Math.round(saturdayRaw)))
      : Number(fallback.saturdayMarkupPercent || 0);
    const sundayRaw = Number(input?.sundayMarkupPercent);
    const sundayMarkupPercent = Number.isFinite(sundayRaw)
      ? Math.max(0, Math.min(300, Math.round(sundayRaw)))
      : Number(fallback.sundayMarkupPercent || 0);
    return {
      name: String(input?.name || fallback.name || 'Тариф'),
      mode: String(input?.mode || fallback.mode || 'system'),
      base,
      perKm,
      perMin,
      includedMin,
      commission,
      saturdayMarkupPercent,
      sundayMarkupPercent,
    };
  }

  private async saveAdminDriverProfile(originalPhone: string, body: Partial<DriverProfile> & Record<string, any>) {
    const targetPhone = String(body?.phone || originalPhone || '').trim();
    if (!targetPhone) return { ok: false, error: 'phone required' };

    const existingRaw = await this.redis.client.get(this.driverProfileKey(originalPhone));
    const targetRaw = targetPhone !== originalPhone ? await this.redis.client.get(this.driverProfileKey(targetPhone)) : null;
    let existing: any = {};
    try {
      if (existingRaw) existing = JSON.parse(existingRaw);
      else if (targetRaw) existing = JSON.parse(targetRaw);
    } catch {
      existing = {};
    }

    const profile = {
      ...existing,
      ...body,
      phone: targetPhone,
      fullName: typeof body?.fullName === 'string' ? body.fullName : (existing.fullName || ''),
      email: typeof body?.email === 'string' ? body.email : (existing.email || ''),
      rating: Number.isFinite(Number(body?.rating)) ? Number(body.rating) : (existing.rating ?? undefined),
      inn: typeof body?.inn === 'string' ? body.inn : (existing.inn || ''),
      passport: typeof body?.passport === 'string' ? body.passport : (existing.passport || ''),
      docsSigned: typeof body?.docsSigned === 'boolean' ? body.docsSigned : Boolean(existing.docsSigned),
      registrationStatus: typeof body?.registrationStatus === 'string' && body.registrationStatus.trim()
        ? body.registrationStatus.trim()
        : (existing.registrationStatus || 'incomplete'),
      updatedAt: new Date().toISOString(),
    };

    await this.drivers.saveProfile(targetPhone, profile);

    if (targetPhone !== originalPhone) {
      const backupRaw = await this.redis.client.get(this.driverPhotosBackupKey(originalPhone));
      const adminComment = await this.redis.client.get(this.driverAdminCommentKey(originalPhone));
      if (backupRaw) await this.redis.client.set(this.driverPhotosBackupKey(targetPhone), backupRaw);
      if (adminComment) await this.redis.client.set(this.driverAdminCommentKey(targetPhone), adminComment);
      await this.redis.client.del(this.driverProfileKey(originalPhone));
      await this.redis.client.del(this.driverPhotosBackupKey(originalPhone));
      await this.redis.client.del(this.driverAdminCommentKey(originalPhone));
      await this.redis.client.srem(this.driversSet(), originalPhone);
    }

    return { ok: true, phone: targetPhone, profile };
  }

  @Get('drivers')
  async listDrivers(
    @Headers('authorization') auth?: string,
    @Query('includePhotos') includePhotos?: string,
  ) {
    this.requireAdmin(auth);
    const includeAllPhotos = includePhotos === '1' || includePhotos === 'true';
    const base = await this.drivers.listDrivers();
    const earningsLimit = await this.orders.getEarningsLimit();
    const pipeline = this.redis.client.pipeline();
    base.forEach((d: any) => pipeline.get(this.driverProfileKey(d.phone)));
    base.forEach((d: any) => pipeline.get(this.driverPhotosBackupKey(d.phone)));
    base.forEach((d: any) => pipeline.hgetall(`driver:earnings:${d.phone}`));
    base.forEach((d: any) => pipeline.get(`driver:sub:paid_until:${d.phone}`));
    base.forEach((d: any) => pipeline.get(this.driverAdminCommentKey(d.phone)));
    const res = await pipeline.exec();
    const half = base.length;
    const profiles = res?.slice(0, half).map((r: any) => r?.[1]) || [];
    const backups = res?.slice(half, half * 2).map((r: any) => r?.[1]) || [];
    const earningsRaw = res?.slice(half * 2, half * 3).map((r: any) => r?.[1]) || [];
    const subPaidRaw = res?.slice(half * 3, half * 4).map((r: any) => r?.[1]) || [];
    const adminComments = res?.slice(half * 4).map((r: any) => r?.[1]) || [];
    const subSettings = await this.drivers.getSubscriptionSettings();
    const currentDue = this.drivers.getCurrentPeriodDueDate(subSettings.dayOfMonth);
    const drivers = base.map((d: any, idx: number) => {
      const raw = typeof profiles[idx] === 'string' ? profiles[idx] : null;
      let profile: any = {};
      try { if (raw) profile = JSON.parse(raw) as DriverProfile; } catch { /* skip corrupted */ }
      const backupRaw = typeof backups[idx] === 'string' ? backups[idx] : null;
      let backup: any = {};
      try { if (backupRaw) backup = JSON.parse(backupRaw); } catch { /* skip corrupted */ }
      const hasVerificationPhotos = !!(
        profile.passportFrontBase64 ||
        profile.passportRegBase64 ||
        profile.driverLicenseBackBase64 ||
        profile.selfieBase64 ||
        backup.passportFrontBase64 ||
        backup.passportRegBase64 ||
        backup.driverLicenseBackBase64 ||
        backup.selfieBase64
      );
      const shouldIncludeVerificationPhotos = includeAllPhotos;
      profile = {
        ...profile,
        hasVerificationPhotos,
        avatarBase64: profile.avatarBase64 || backup.avatarBase64 || null,
        passportFrontBase64: shouldIncludeVerificationPhotos
          ? (profile.passportFrontBase64 || backup.passportFrontBase64 || null)
          : null,
        passportRegBase64: shouldIncludeVerificationPhotos
          ? (profile.passportRegBase64 || backup.passportRegBase64 || null)
          : null,
        driverLicenseBackBase64: shouldIncludeVerificationPhotos
          ? (profile.driverLicenseBackBase64 || backup.driverLicenseBackBase64 || null)
          : null,
        selfieBase64: shouldIncludeVerificationPhotos
          ? (profile.selfieBase64 || backup.selfieBase64 || null)
          : null,
      };
      const e = (earningsRaw[idx] || {}) as Record<string, string>;
      const gross = Number(e.gross || 0);
      const commission = Number(e.commission || 0);
      const net = Number(e.net || 0);
      const paid = Number(e.paid || 0);
      const paidUntil = typeof subPaidRaw[idx] === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(subPaidRaw[idx] as string) ? (subPaidRaw[idx] as string) : null;
      const subscriptionOverdue = !paidUntil || paidUntil < currentDue;
      return {
        ...d,
        profile,
        adminComment: typeof adminComments[idx] === 'string' ? (adminComments[idx] as string) : '',
        earnings: { gross, commission, net, paid, available: net - paid },
        limitReached: commission >= earningsLimit,
        earningsLimit,
        subscriptionPaidUntil: paidUntil,
        subscriptionOverdue,
        subscriptionAmount: subSettings.amount,
        subscriptionDayOfMonth: subSettings.dayOfMonth,
      };
    });
    return { ok: true, drivers };
  }

  @Post('drivers')
  async upsertDriver(@Body() body: DriverProfile, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (body.phone || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    return this.saveAdminDriverProfile(phone, body as any);
  }

  @Post('drivers/:phone')
  async updateDriverProfile(
    @Param('phone') phoneRaw: string,
    @Body() body: Partial<DriverProfile> & Record<string, any>,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    return this.saveAdminDriverProfile(phone, body as any);
  }

  @Post('drivers/:phone/block')
  async blockDriver(
    @Param('phone') phoneRaw: string,
    @Body() body: { reason?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    const reason = (body?.reason || '').trim() || 'manual';
    await this.drivers.blockTemporarily(phone, reason, 24 * 365);
    const meta = await this.drivers.getBlockMeta(phone);
    this.events.emitDriverBlocked(phone, { reason: meta?.reason || reason, until: meta?.until || null });
    return { ok: true, reason: meta?.reason || reason, until: meta?.until || null };
  }

  @Post('drivers/:phone/unblock')
  async unblockDriver(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    await this.drivers.clearBlock(phone);
    this.events.emitDriverUnblocked(phone);
    return { ok: true };
  }

  @Post('drivers/:phone/delete')
  async deleteDriver(
    @Param('phone') phoneRaw: string,
    @Body() body: { comment?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    const comment = (body?.comment || '').trim();
    if (comment) {
      await this.redis.client.set(this.driverAdminCommentKey(phone), comment);
    }
    await this.drivers.clearBlock(phone);
    await this.redis.client.del(this.driverProfileKey(phone));
    await this.redis.client.del(this.driverPhotosBackupKey(phone));
    await this.redis.client.del(this.driverLocKey(phone));
    await this.redis.client.del(this.driverPushTokenKey(phone));
    await this.redis.client.srem(this.driversSet(), phone);
    await this.redis.client.hdel(this.driverStatusKey(), phone);
    try {
      await this.redis.client.zrem(this.driverGeoKey(), phone);
    } catch {
      // geo index cleanup is best-effort
    }
    await this.redis.client.srem('drivers:active_order', phone);
    await this.redis.client.del(`driver:sub:paid_until:${phone}`);
    return { ok: true };
  }

  @Get('subscription/settings')
  async getSubscriptionSettings(@Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const settings = await this.drivers.getSubscriptionSettings();
    return { ok: true, ...settings };
  }

  @Post('subscription/settings')
  async setSubscriptionSettings(
    @Body() body: { amount?: number; dayOfMonth?: number },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const current = await this.drivers.getSubscriptionSettings();
    const amount = Number.isFinite(Number(body?.amount)) ? Math.max(0, Math.round(Number(body.amount))) : current.amount;
    const dayOfMonth = Number.isFinite(Number(body?.dayOfMonth)) ? Math.max(1, Math.min(28, Math.round(Number(body.dayOfMonth)))) : current.dayOfMonth;
    await this.drivers.setSubscriptionSettings(amount, dayOfMonth);
    return { ok: true, amount, dayOfMonth };
  }

  @Post('drivers/:phone/subscription/paid')
  async markSubscriptionPaid(
    @Param('phone') phoneRaw: string,
    @Body() body: { paidUntil?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    const nextDue = this.drivers.getNextDueDate((await this.drivers.getSubscriptionSettings()).dayOfMonth);
    const paidUntil = body?.paidUntil && /^\d{4}-\d{2}-\d{2}$/.test(String(body.paidUntil).trim()) ? String(body.paidUntil).trim() : nextDue;
    await this.drivers.setSubscriptionPaidUntil(phone, paidUntil);
    this.events.emitDriverSubscriptionPaid(phone);
    return { ok: true, paidUntil };
  }

  @Post('drivers/:phone/subscription/force-overdue')
  async forceSubscriptionOverdue(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    const settings = await this.drivers.getSubscriptionSettings();
    const currentDue = this.drivers.getCurrentPeriodDueDate(settings.dayOfMonth);
    const dueDate = new Date(currentDue + 'T12:00:00Z');
    dueDate.setDate(dueDate.getDate() - 1);
    const paidUntil = dueDate.toISOString().slice(0, 10);
    await this.drivers.setSubscriptionPaidUntil(phone, paidUntil);
    this.events.emitDriverSubscriptionOverdue(phone);
    return { ok: true, paidUntil };
  }

  @Post('drivers/:phone/subscription/set-date')
  async setSubscriptionDate(
    @Param('phone') phoneRaw: string,
    @Body() body: { paidUntil: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    const paidUntil = body?.paidUntil && /^\d{4}-\d{2}-\d{2}$/.test(String(body.paidUntil).trim()) ? String(body.paidUntil).trim() : null;
    if (!paidUntil) return { ok: false, error: 'paidUntil required (YYYY-MM-DD)' };
    await this.drivers.setSubscriptionPaidUntil(phone, paidUntil);
    this.events.emitDriverSubscriptionPaid(phone);
    return { ok: true, paidUntil };
  }

  @Post('drivers/:phone/approve')
  async approveDriver(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    const raw = await this.redis.client.get(this.driverProfileKey(phone));
    if (!raw) return { ok: false, error: 'profile not found' };
    let profile: any = {};
    try { profile = JSON.parse(raw); } catch { profile = {}; }
    profile.registrationStatus = 'completed';
    profile.approvedAt = new Date().toISOString();
    await this.redis.client.set(this.driverProfileKey(phone), JSON.stringify(profile));
    return { ok: true };
  }

  @Post('drivers/:phone/reject')
  async rejectDriver(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    const raw = await this.redis.client.get(this.driverProfileKey(phone));
    if (!raw) return { ok: false, error: 'profile not found' };
    let profile: any = {};
    try { profile = JSON.parse(raw); } catch { profile = {}; }
    profile.registrationStatus = 'rejected';
    profile.rejectedAt = new Date().toISOString();
    await this.redis.client.set(this.driverProfileKey(phone), JSON.stringify(profile));
    return { ok: true };
  }

  @Get('drivers/:phone/orders')
  async listDriverOrders(
    @Param('phone') phoneRaw: string,
    @Query('limit') limitRaw?: string,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: true, orders: [] };
    const limit = Math.min(200, Math.max(1, Number(limitRaw) || 50));
    const orders = await this.orders.listOrdersForDriver(phone, limit);
    return { ok: true, orders };
  }

  @Get('drivers/:phone/earnings')
  async driverEarnings(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    const earnings = await this.orders.getDriverEarnings(phone);
    return { ok: true, earnings };
  }

  @Get('drivers/:phone')
  async getDriverProfile(
    @Param('phone') phoneRaw: string,
    @Query('includePhotos') includePhotos?: string,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };

    const includeAllPhotos = includePhotos === '1' || includePhotos === 'true';
    const raw = await this.redis.client.get(this.driverProfileKey(phone));
    const backupRaw = await this.redis.client.get(this.driverPhotosBackupKey(phone));
    if (!raw && !backupRaw) return { ok: false, error: 'not found' };

    let profile: any = {};
    try { if (raw) profile = JSON.parse(raw); } catch { /* skip */ }
    let backup: any = {};
    try { if (backupRaw) backup = JSON.parse(backupRaw); } catch { /* skip */ }
    const blockMeta = await this.drivers.getBlockMeta(phone);
    const adminComment = await this.redis.client.get(this.driverAdminCommentKey(phone));

    const regStatus = profile.registrationStatus || 'incomplete';
    const shouldIncludeVerificationPhotos = includeAllPhotos || regStatus === 'pending';
    const safeProfile = {
      ...profile,
      avatarBase64: profile.avatarBase64 || backup.avatarBase64 || null,
      passportFrontBase64: shouldIncludeVerificationPhotos
        ? (profile.passportFrontBase64 || backup.passportFrontBase64 || null)
        : null,
      passportRegBase64: shouldIncludeVerificationPhotos
        ? (profile.passportRegBase64 || backup.passportRegBase64 || null)
        : null,
      driverLicenseBackBase64: shouldIncludeVerificationPhotos
        ? (profile.driverLicenseBackBase64 || backup.driverLicenseBackBase64 || null)
        : null,
      selfieBase64: shouldIncludeVerificationPhotos
        ? (profile.selfieBase64 || backup.selfieBase64 || null)
        : null,
    };

    return {
      ok: true,
      profile: safeProfile,
      blockReason: blockMeta?.reason || null,
      blockUntil: blockMeta?.until || null,
      adminComment: adminComment || '',
    };
  }

  /** Погасить комиссию: обнуляем earnings водителя */
  @Post('drivers/:phone/commission/clear')
  async clearCommission(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false };
    const earnings = await this.orders.getDriverEarnings(phone);
    await this.redis.client.hset(`driver:earnings:${phone}`, {
      commission: '0',
    });
    // Уведомляем водителя через сокет — лимит снят
    this.events.emitCommissionCleared(phone);
    return { ok: true, cleared: earnings };
  }

  @Get('clients')
  async listClients(@Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const ids = await this.redis.client.smembers(this.clientsSet());
    if (!ids.length) return { ok: true, clients: [] };
    const pipeline = this.redis.client.pipeline();
    ids.forEach((id: string) => pipeline.get(this.clientProfileKey(id)));
    ids.forEach((id: string) => pipeline.get(this.clientBlockKey(id)));
    ids.forEach((id: string) => pipeline.get(this.clientBlockMetaKey(id)));
    ids.forEach((id: string) => pipeline.llen(`client:orders:${id}`));
    ids.forEach((id: string) => pipeline.get(this.clientAdminCommentKey(id)));
    const res = await pipeline.exec();
    const split = ids.length;
    const clients = ids.map((id: string, idx: number) => {
      const raw = typeof res?.[idx]?.[1] === 'string' ? (res?.[idx]?.[1] as string) : null;
      let profile: any = { id };
      try { if (raw) profile = JSON.parse(raw) as ClientProfile; } catch { /* skip corrupted */ }
      const blockRaw = typeof res?.[split + idx]?.[1] === 'string' ? (res?.[split + idx]?.[1] as string) : null;
      const blockMetaRaw = typeof res?.[split * 2 + idx]?.[1] === 'string' ? (res?.[split * 2 + idx]?.[1] as string) : null;
      let legacyBlock: any = null;
      try { if (blockRaw) legacyBlock = JSON.parse(blockRaw); } catch { legacyBlock = null; }
      let blockMeta: any = null;
      try { if (blockMetaRaw) blockMeta = JSON.parse(blockMetaRaw); } catch { blockMeta = null; }
      const blocked = !!blockRaw;
      const orderCountRaw = res?.[split * 3 + idx]?.[1];
      const orderCount = Number(orderCountRaw) || 0;
      const adminComment = typeof res?.[split * 4 + idx]?.[1] === 'string' ? (res?.[split * 4 + idx]?.[1] as string) : '';
      return {
        ...profile,
        blocked,
        blockReason: blockMeta?.reason || legacyBlock?.reason || null,
        blockUntil: blockMeta?.until || legacyBlock?.until || null,
        blockedAt: blockMeta?.blockedAt || legacyBlock?.blockedAt || null,
        adminComment,
        orderCount,
      };
    });
    return { ok: true, clients };
  }

  @Post('clients')
  async upsertClient(@Body() body: ClientProfile, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const id = (body.id || '').trim();
    if (!id) return { ok: false, error: 'id required' };
    await this.redis.client.set(this.clientProfileKey(id), JSON.stringify(body));
    await this.redis.client.sadd(this.clientsSet(), id);
    return { ok: true };
  }

  @Post('clients/:id/block')
  async blockClient(
    @Param('id') idRaw: string,
    @Body() body: { reason?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const id = (idRaw || '').trim();
    if (!id) return { ok: false };
    const reason = (body?.reason || '').trim() || 'manual';
    const ttlSec = 60 * 60 * 24 * 365;
    await this.redis.client.set(this.clientBlockKey(id), '1', 'EX', ttlSec);
    await this.redis.client.set(
      this.clientBlockMetaKey(id),
      JSON.stringify({ reason, blockedAt: new Date().toISOString() }),
      'EX',
      ttlSec,
    );
    return { ok: true, reason };
  }

  @Get('promos')
  async listPromos(@Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const codes = await this.redis.client.smembers(this.promoSet());
    if (!codes.length) return { ok: true, promos: [] };
    const pipeline = this.redis.client.pipeline();
    codes.forEach((code: string) => pipeline.hgetall(this.promoKey(code)));
    const res = await pipeline.exec();
    const promos = codes.map((code: string, idx: number) => {
      const raw = (res?.[idx]?.[1] as Record<string, string>) || {};
      return {
        code,
        discount: Number(raw.discount || 0),
        active: raw.active !== 'false',
        expiresAt: raw.expiresAt || '',
        createdAt: raw.createdAt || '',
      };
    });
    return { ok: true, promos };
  }

  @Post('promos')
  async upsertPromo(
    @Body() body: { code?: string; discount?: number; active?: boolean; expiresAt?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const code = (body.code || '').toString().trim().toLowerCase();
    const discount = Math.max(0, Math.min(90, Math.round(Number(body.discount) || 0)));
    if (!code) return { ok: false, error: 'code required' };
    if (discount <= 0) return { ok: false, error: 'discount required' };
    const active = body.active !== false;
    const expiresAt = (body.expiresAt || '').toString().trim();
    const data: Record<string, string> = {
      code,
      discount: String(discount),
      active: active ? 'true' : 'false',
      updatedAt: new Date().toISOString(),
    };
    if (expiresAt) data.expiresAt = expiresAt;
    const existing = await this.redis.client.hgetall(this.promoKey(code));
    if (!existing || Object.keys(existing).length === 0) {
      data.createdAt = new Date().toISOString();
    }
    await this.redis.client.hset(this.promoKey(code), data);
    await this.redis.client.sadd(this.promoSet(), code);
    return { ok: true };
  }

  @Post('promos/:code/disable')
  async disablePromo(@Param('code') codeRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const code = (codeRaw || '').toString().trim().toLowerCase();
    if (!code) return { ok: false };
    await this.redis.client.hset(this.promoKey(code), {
      active: 'false',
      updatedAt: new Date().toISOString(),
    });
    return { ok: true };
  }

  @Post('clients/:id/unblock')
  async unblockClient(@Param('id') idRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const id = (idRaw || '').trim();
    if (!id) return { ok: false };
    await this.redis.client.del(this.clientBlockKey(id));
    await this.redis.client.del(this.clientBlockMetaKey(id));
    return { ok: true };
  }

  @Get('clients/:id/orders')
  async listClientOrders(
    @Param('id') idRaw: string,
    @Query('limit') limitRaw?: string,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const id = (idRaw || '').trim();
    if (!id) return { ok: true, orders: [] };
    const limit = Math.min(200, Math.max(1, Number(limitRaw) || 50));
    const orders = await this.orders.listOrdersForClient(id, limit);
    return { ok: true, orders };
  }

  @Get('tariffs')
  async listTariffs(@Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const raw = await this.redis.client.get('tariffs:list');
    let tariffs: any[] = [];
    try { if (raw) tariffs = JSON.parse(raw); } catch { /* corrupted tariffs */ }
    if (!tariffs.length) {
      tariffs = this.defaultTariffs();
    }
    return { ok: true, tariffs };
  }

  @Post('tariffs')
  async saveTariffs(@Body() body: { tariffs?: any[] }, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const defaults = this.defaultTariffs();
    const rawList = Array.isArray(body.tariffs) ? body.tariffs : [];
    const source = rawList.length ? rawList : defaults;
    const tariffs = source.map((item, idx) => this.normalizeTariff(item, defaults[idx] || defaults[0]));
    await this.redis.client.set('tariffs:list', JSON.stringify(tariffs));
    return { ok: true };
  }

  @Get('stats/orders')
  async statsOrders(
    @Query('period') periodRaw?: string,
    @Query('mode') modeRaw?: string,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const period = (['hour', 'day', 'month', 'year'].includes(periodRaw || '') ? periodRaw : 'day') as string;
    const mode = (['orders', 'company', 'drivers'].includes(modeRaw || '') ? modeRaw : 'orders') as string;

    const allOrders = await this.orders.getAllOrdersForStats(2000);

    // Helper: format number with spaces
    const fmt = (n: number) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');

    // Helper: group orders into buckets
    type Bucket = { total: number; completed: number; canceled: number; revenue: number };
    const makeBucket = (): Bucket => ({ total: 0, completed: 0, canceled: 0, revenue: 0 });

    const now = new Date();

    if (period === 'hour') {
      const labels = Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0'));
      const buckets = labels.map(() => makeBucket());
      const cutoff = now.getTime() - 24 * 60 * 60 * 1000;
      for (const o of allOrders) {
        const ts = Date.parse(o.createdAt);
        if (ts < cutoff) continue;
        const h = new Date(ts).getHours();
        buckets[h].total++;
        if (o.status === 'completed') { buckets[h].completed++; buckets[h].revenue += Number(o.priceFinal || o.priceFrom || 0); }
        if (o.status === 'canceled') buckets[h].canceled++;
      }
      return this.buildStatsResponse(period, mode, labels, buckets, allOrders, cutoff);
    }

    if (period === 'day') {
      const dayNames = ['Вс', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб'];
      const labels = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
      const buckets = labels.map(() => makeBucket());
      const cutoff = now.getTime() - 7 * 24 * 60 * 60 * 1000;
      for (const o of allOrders) {
        const ts = Date.parse(o.createdAt);
        if (ts < cutoff) continue;
        const jsDay = new Date(ts).getDay(); // 0=Sun
        const idx = jsDay === 0 ? 6 : jsDay - 1; // Mon=0 .. Sun=6
        buckets[idx].total++;
        if (o.status === 'completed') { buckets[idx].completed++; buckets[idx].revenue += Number(o.priceFinal || o.priceFrom || 0); }
        if (o.status === 'canceled') buckets[idx].canceled++;
      }
      return this.buildStatsResponse(period, mode, labels, buckets, allOrders, cutoff);
    }

    if (period === 'month') {
      const monthNames = ['Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'];
      const labels: string[] = [];
      const buckets: Bucket[] = [];
      for (let i = 5; i >= 0; i--) {
        const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
        labels.push(monthNames[d.getMonth()]);
        buckets.push(makeBucket());
      }
      const sixMonthsAgo = new Date(now.getFullYear(), now.getMonth() - 5, 1).getTime();
      for (const o of allOrders) {
        const ts = Date.parse(o.createdAt);
        if (ts < sixMonthsAgo) continue;
        const d = new Date(ts);
        const monthDiff = (now.getFullYear() - d.getFullYear()) * 12 + (now.getMonth() - d.getMonth());
        const idx = 5 - monthDiff;
        if (idx < 0 || idx >= 6) continue;
        buckets[idx].total++;
        if (o.status === 'completed') { buckets[idx].completed++; buckets[idx].revenue += Number(o.priceFinal || o.priceFrom || 0); }
        if (o.status === 'canceled') buckets[idx].canceled++;
      }
      return this.buildStatsResponse(period, mode, labels, buckets, allOrders, sixMonthsAgo);
    }

    // year
    const yearsSet = new Set<number>();
    for (const o of allOrders) {
      const y = new Date(Date.parse(o.createdAt)).getFullYear();
      if (y > 2000) yearsSet.add(y);
    }
    const years = [...yearsSet].sort((a, b) => a - b);
    if (years.length === 0) years.push(now.getFullYear());
    const labels = years.map(String);
    const buckets = labels.map(() => makeBucket());
    for (const o of allOrders) {
      const y = new Date(Date.parse(o.createdAt)).getFullYear();
      const idx = years.indexOf(y);
      if (idx < 0) continue;
      buckets[idx].total++;
      if (o.status === 'completed') { buckets[idx].completed++; buckets[idx].revenue += Number(o.priceFinal || o.priceFrom || 0); }
      if (o.status === 'canceled') buckets[idx].canceled++;
    }
    return this.buildStatsResponse(period, mode, labels, buckets, allOrders, 0);
  }

  private buildStatsResponse(
    period: string,
    mode: string,
    labels: string[],
    buckets: { total: number; completed: number; canceled: number; revenue: number }[],
    allOrders: any[],
    cutoff: number,
  ) {
    const fmt = (n: number) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
    const periodNames: Record<string, string> = {
      hour: 'по часам', day: 'по дням недели', month: 'по месяцам', year: 'по годам',
    };
    const periodLabel = periodNames[period] || period;

    const filteredOrders = cutoff > 0
      ? allOrders.filter((o: any) => Date.parse(o.createdAt) >= cutoff)
      : allOrders;
    const totalAll = filteredOrders.length;
    const completedAll = filteredOrders.filter((o: any) => o.status === 'completed').length;
    const canceledAll = filteredOrders.filter((o: any) => o.status === 'canceled').length;
    const revenueAll = filteredOrders
      .filter((o: any) => o.status === 'completed')
      .reduce((s: number, o: any) => s + Number(o.priceFinal || o.priceFrom || 0), 0);
    const avgCheck = completedAll > 0 ? Math.round(revenueAll / completedAll) : 0;
    const conversionPct = totalAll > 0 ? Math.round((completedAll / totalAll) * 100) : 0;
    const cancelPct = totalAll > 0 ? ((canceledAll / totalAll) * 100).toFixed(1) : '0';

    if (mode === 'orders') {
      return {
        ok: true,
        title: `Статистика заказов ${periodLabel}`,
        labels,
        series: [
          { name: 'Завершено', values: buckets.map((b) => b.completed) },
          { name: 'Отменено', values: buckets.map((b) => b.canceled) },
          { name: 'Новые', values: buckets.map((b) => b.total) },
        ],
        list: [
          { k: 'Всего заказов', v: fmt(totalAll) },
          { k: 'Завершено', v: fmt(completedAll) },
          { k: 'Отменено', v: fmt(canceledAll) },
          { k: 'Конверсия', v: `${conversionPct}%` },
        ],
      };
    }

    if (mode === 'company') {
      return {
        ok: true,
        title: `Заказы ${periodLabel} (компания)`,
        labels,
        series: [
          { name: 'Заказы', values: buckets.map((b) => b.total) },
          { name: 'Доход (тыс)', values: buckets.map((b) => Math.round(b.revenue / 1000)) },
          { name: 'Отмены', values: buckets.map((b) => b.canceled) },
        ],
        list: [
          { k: 'Заказов', v: fmt(totalAll) },
          { k: 'Доход', v: `${fmt(Math.round(revenueAll))} ₽` },
          { k: 'Средний чек', v: `${fmt(avgCheck)} ₽` },
          { k: 'Отмены', v: `${cancelPct}%` },
        ],
      };
    }

    // mode === 'drivers'
    const driverPhones = new Set<string>();
    filteredOrders.forEach((o: any) => { if (o.driverPhone) driverPhones.add(o.driverPhone); });
    return {
      ok: true,
      title: `Поездки ${periodLabel} (водители)`,
      labels,
      series: [
        { name: 'Поездки', values: buckets.map((b) => b.completed) },
        { name: 'Заказы', values: buckets.map((b) => b.total) },
        { name: 'Отмены', values: buckets.map((b) => b.canceled) },
      ],
      list: [
        { k: 'Активных водителей', v: String(driverPhones.size) },
        { k: 'Поездок', v: fmt(completedAll) },
        { k: 'Заказов', v: fmt(totalAll) },
        { k: 'Отмены водителями', v: `${cancelPct}%` },
      ],
    };
  }

  @Post('orders/:id/cancel')
  async adminCancel(
    @Param('id') id: string,
    @Body() body: { reason?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const order = await this.orders.adminCancel(id, body?.reason);
    this.events.emitOrderStatus(order);
    return { ok: true, order };
  }

  @Post('orders/:id/assign')
  async assignOrder(
    @Param('id') id: string,
    @Body() body: { driverPhone?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const driverPhone = (body?.driverPhone || '').trim();
    if (!driverPhone) return { ok: false, error: 'driverPhone required' };
    const order = await this.orders.assignDriver(id, driverPhone);
    this.events.emitOrderNew(order, [driverPhone]);
    this.events.emitOrderStatus(order);
    return { ok: true, order };
  }

  @Post('orders/:id/pay')
  async adminPay(@Param('id') id: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const order = await this.orders.markPaid(id);
    return { ok: true, order };
  }

  @Get('payouts')
  async listPayouts(
    @Query('limit') limitRaw?: string,
    @Query('driverPhone') driverPhone?: string,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const limit = Math.min(200, Math.max(1, Number(limitRaw) || 50));
    const payouts = await this.orders.listPayouts(limit, driverPhone?.trim() || undefined);
    return { ok: true, payouts };
  }

  @Post('payouts')
  async createPayout(
    @Body() body: { driverPhone?: string; amount?: number; orderId?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const driverPhone = (body.driverPhone || '').trim();
    const amount = Number(body.amount || 0);
    if (!driverPhone || !Number.isFinite(amount) || amount <= 0) {
      return { ok: false, error: 'driverPhone and amount required' };
    }
    const payout = await this.orders.createPayout({
      driverPhone,
      amount,
      orderId: body.orderId?.trim(),
    });
    return { ok: true, payout };
  }

  // Driver admin comments
  @Get('drivers/:phone/comment')
  async getDriverComment(@Param('phone') phoneRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    const comment = await this.redis.client.get(this.driverAdminCommentKey(phone));
    return { ok: true, comment: comment || '' };
  }

  @Post('drivers/:phone/comment')
  async setDriverComment(
    @Param('phone') phoneRaw: string,
    @Body() body: { comment?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const phone = (phoneRaw || '').trim();
    if (!phone) return { ok: false, error: 'phone required' };
    const key = this.driverAdminCommentKey(phone);
    if (!body?.comment || !body.comment.trim()) {
      await this.redis.client.del(key);
      return { ok: true, comment: '' };
    }
    await this.redis.client.set(key, body.comment.trim());
    return { ok: true, comment: body.comment.trim() };
  }

  // Client admin comments
  @Get('clients/:id/comment')
  async getClientComment(@Param('id') idRaw: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const id = (idRaw || '').trim();
    if (!id) return { ok: false, error: 'id required' };
    const comment = await this.redis.client.get(this.clientAdminCommentKey(id));
    return { ok: true, comment: comment || '' };
  }

  @Post('clients/:id/comment')
  async setClientComment(
    @Param('id') idRaw: string,
    @Body() body: { comment?: string },
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const id = (idRaw || '').trim();
    if (!id) return { ok: false, error: 'id required' };
    const key = this.clientAdminCommentKey(id);
    if (!body?.comment || !body.comment.trim()) {
      await this.redis.client.del(key);
      return { ok: true, comment: '' };
    }
    await this.redis.client.set(key, body.comment.trim());
    return { ok: true, comment: body.comment.trim() };
  }
}
