import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { RedisService } from './redis.service';
import { DriversService } from './drivers.service';
import crypto from 'crypto';

export type OrderStatus = 'searching' | 'accepted' | 'enroute' | 'arrived' | 'started' | 'completed' | 'canceled';

export type LatLng = {
  lat: number;
  lng: number;
};

export type PaymentStatus = 'unpaid' | 'paid' | 'failed';

export type Order = {
  id: string;
  clientId: string;
  from: LatLng;
  to: LatLng;
  fromAddress?: string;
  toAddress?: string;
  comment?: string;
  wish?: string;
  serviceIndex?: number;
  priceFrom?: number;
  priceFinal?: number;
  promoDiscountPercent?: number;
  bonusUsed?: number;
  tripMinutes?: number;
  tariffName?: string;
  paymentMethod?: 'sbp' | 'cash';
  paymentStatus?: PaymentStatus;
  cancelReason?: string;
  canceledBy?: 'client' | 'admin';
  commissionPercent?: number;
  commissionAmount?: number;
  rating?: number;
  ratedAt?: string;
  routeDistanceMeters?: number;
  routeEtaSeconds?: number;
  kmOutsideMkad?: number;
  scheduledAt?: string;
  status: OrderStatus;
  driverPhone?: string;
  acceptedAt?: string;
  arrivedAt?: string;
  startedAt?: string;
  completedAt?: string;
  createdAt: string;
};

export type CreateOrderInput = {
  clientId: string;
  requestId?: string;
  from: LatLng;
  to: LatLng;
  fromAddress?: string;
  toAddress?: string;
  comment?: string;
  wish?: string;
  serviceIndex?: number;
  routeDistanceMeters?: number;
  routeEtaSeconds?: number;
  kmOutsideMkad?: number;
  paymentMethod?: 'sbp' | 'cash';
  scheduledAt?: string;
  discountPercent?: number;
  bonusAmount?: number;
};

function isFiniteNumber(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v);
}

function validatePoint(p: unknown, name: string): asserts p is LatLng {
  if (typeof p !== 'object' || p === null) {
    throw new BadRequestException(`${name} is required`);
  }
  const anyP = p as any;
  if (!isFiniteNumber(anyP.lat) || !isFiniteNumber(anyP.lng)) {
    throw new BadRequestException(`${name}.lat and ${name}.lng must be numbers`);
  }
}

@Injectable()
export class OrdersService {
  constructor(
    private readonly redis: RedisService,
    private readonly drivers: DriversService,
  ) {}

  private static readonly center = { lat: 55.755864, lng: 37.617698 };
  private static readonly mkadRadiusKm = 17.0;
  private static readonly mkadToleranceKm = 2.5;
  private static readonly ckadRadiusKm = 50.0;

  private orderKey(orderId: string) {
    return `order:${orderId}`;
  }

  private acceptLockKey(orderId: string) {
    return `order:accept_lock:${orderId}`;
  }

  private orderLockKey(orderId: string) {
    return `order:lock:${orderId}`;
  }

  private orderRequestKey(clientId: string, requestId: string) {
    return `order:req:${clientId}:${requestId}`;
  }

  private orderRequestLockKey(clientId: string, requestId: string) {
    return `order:req_lock:${clientId}:${requestId}`;
  }

  private declineSetKey(orderId: string) {
    return `order:declines:${orderId}`;
  }

  private recentListKey() {
    return 'orders:recent';
  }

  private searchingOrdersKey() {
    return 'orders:searching';
  }

  private driverOrdersKey(phone: string) {
    return `driver:orders:${phone}`;
  }

  private clientOrdersKey(id: string) {
    return `client:orders:${id}`;
  }

  private clientProfileKey(id: string) {
    return `client:profile:${id}`;
  }

  private clientBonusKey(id: string) {
    return `client:bonus:${id}`;
  }

  private driverEarningsKey(phone: string) {
    return `driver:earnings:${phone}`;
  }

  private payoutsListKey() {
    return 'payouts:recent';
  }

  private payoutKey(id: string) {
    return `payout:${id}`;
  }

  async listSearchingOrderIds(): Promise<string[]> {
    const ids = await this.redis.client.smembers(this.searchingOrdersKey());
    return (ids || []).map((id: string) => String(id || '').trim()).filter(Boolean);
  }

  async markOrderSearching(orderId: string): Promise<void> {
    if (!orderId) return;
    await this.redis.client.sadd(this.searchingOrdersKey(), orderId);
  }

  async unmarkOrderSearching(orderId: string): Promise<void> {
    if (!orderId) return;
    await this.redis.client.srem(this.searchingOrdersKey(), orderId);
    await this.redis.client.del(this.declineSetKey(orderId));
  }

  private driverRatingKey(phone: string) {
    return `driver:rating:${phone}`;
  }

  async getDriverRating(phone: string) {
    const raw = await this.redis.client.hgetall(this.driverRatingKey(phone));
    const sum = Number(raw.sum || 0);
    const count = Number(raw.count || 0);
    const avg = Number(raw.avg || 0);
    const computed = count > 0 ? Math.round((sum / count) * 10) / 10 : avg;
    return { avg: computed, count };
  }

  private routeMinutes(seconds?: number) {
    const s = Number(seconds || 0);
    if (!Number.isFinite(s) || s <= 0) return 0;
    return Math.ceil(s / 60);
  }

  private computePriceByMinutes(serviceIndex: number, _from: LatLng, _to: LatLng, minutes: number, _routeDistanceMeters?: number, kmOutsideMkad = 0) {
    const safeMinutes = Math.max(1, Math.ceil(minutes));

    if (serviceIndex === 1) {
      const includedMin = 5 * 60;
      const extraMin = Math.max(0, safeMinutes - includedMin);
      return 9000 + extraMin * 25;
    }

    // serviceIndex 0 (Трезвый водитель) и 2 (Перегон) — одна формула
    const outsideMkad = kmOutsideMkad > 0.5; // >500m = выезд за МКАД
    const includedMin = 60;
    const extraMin = Math.max(0, safeMinutes - includedMin);
    const base = outsideMkad ? 2900 : 2500;
    const kmCharge = outsideMkad ? this.kmFee(kmOutsideMkad) : 0;
    return base + extraMin * 25 + kmCharge;
  }

  private async computeFinalPrice(order: Order) {
    if (!order.startedAt || !order.completedAt) return null;
    const start = Date.parse(order.startedAt);
    const end = Date.parse(order.completedAt);
    if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
    const minutes = Math.max(1, Math.ceil((end - start) / 60000));
    const serviceIndex = Number(order.serviceIndex ?? 0);
    const kmOutside = Number(order.kmOutsideMkad || 0);
    const calculated = this.computePriceByMinutes(serviceIndex, order.from, order.to, minutes, order.routeDistanceMeters, kmOutside);
    const priceFrom = this.safeNum(order.priceFrom, 0);
    let price = Math.max(calculated, priceFrom);
    const promoPercent = Math.max(0, Math.min(100, Number(order.promoDiscountPercent || 0)));
    if (promoPercent > 0) {
      price = Math.round(price * (1 - promoPercent / 100));
    }
    const tariffs = await this.loadTariffs();
    const tariff = tariffs[this.safeNum(order.serviceIndex, 0)];
    price = this.applyWeekendMarkup(price, tariff, order.scheduledAt);
    const bonusUsed = Math.max(0, Math.round(Number(order.bonusUsed) || 0));
    if (bonusUsed > 0) price = Math.max(0, price - bonusUsed);
    return { price, minutes };
  }

  private kmFee(km: number) {
    const k = km <= 0 ? 0 : Math.ceil(km);
    return k * 50;
  }

  private distanceKm(a: LatLng, b: LatLng) {
    const earthRadiusKm = 6371.0;
    const lat1 = (a.lat * Math.PI) / 180.0;
    const lat2 = (b.lat * Math.PI) / 180.0;
    const dLat = lat2 - lat1;
    const dLon = ((b.lng - a.lng) * Math.PI) / 180.0;

    const sinDLat = Math.sin(dLat / 2);
    const sinDLon = Math.sin(dLon / 2);
    const h = sinDLat * sinDLat + Math.cos(lat1) * Math.cos(lat2) * sinDLon * sinDLon;
    const c = 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
    return earthRadiusKm * c;
  }

  private computeLegacyPrice(input: CreateOrderInput) {
    const minutes = this.routeMinutes(input.routeEtaSeconds);
    const kmOutside = Math.max(0, Number(input.kmOutsideMkad || 0));

    if (Number(input.serviceIndex) === 1) {
      const includedMin = 5 * 60;
      const extraMin = Math.max(0, minutes - includedMin);
      const priceFrom = 9000 + extraMin * 25;
      return { priceFrom, tariffName: 'Личный водитель' };
    }

    const tariffName = Number(input.serviceIndex) === 2 ? 'Перегон автомобиля' : 'Трезвый водитель';
    const outsideMkad = kmOutside > 0.5;
    const includedMin = 60;
    const extraMin = Math.max(0, minutes - includedMin);
    const base = outsideMkad ? 2900 : 2500;
    const kmCharge = outsideMkad ? this.kmFee(kmOutside) : 0;
    const priceFrom = base + extraMin * 25 + kmCharge;
    return { priceFrom, tariffName };
  }

  private resolvePricingDate(scheduledAt?: string) {
    if (!scheduledAt) return new Date();
    const date = new Date(scheduledAt);
    return Number.isNaN(date.getTime()) ? new Date() : date;
  }

  private weekendMarkupPercent(tariff: any, scheduledAt?: string) {
    if (!tariff) return 0;
    const day = this.resolvePricingDate(scheduledAt).getDay();
    if (day === 6) return Math.max(0, this.safeNum(tariff.saturdayMarkupPercent));
    if (day === 0) return Math.max(0, this.safeNum(tariff.sundayMarkupPercent));
    return 0;
  }

  private applyWeekendMarkup(priceFrom: number, tariff: any, scheduledAt?: string) {
    const percent = this.weekendMarkupPercent(tariff, scheduledAt);
    if (!Number.isFinite(priceFrom) || priceFrom <= 0 || percent <= 0) return priceFrom;
    return Math.round(priceFrom * (1 + percent / 100));
  }

  private defaultTariffs() {
    return [
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
  }

  private async loadTariffs() {
    try {
      const raw = await this.redis.client.get('tariffs:list');
      const list = raw ? (JSON.parse(raw) as any[]) : [];
      if (Array.isArray(list) && list.length) return list;
    } catch {
      // Ignore corrupted Redis value and use built-in defaults.
    }
    return this.defaultTariffs();
  }

  private safeNum(v: any, fallback = 0): number {
    const n = Number(v);
    return Number.isFinite(n) ? n : fallback;
  }

  private async computeCommission(order: Order) {
    const list = await this.loadTariffs();
    const index = this.safeNum(order.serviceIndex, 0);
    const tariff = list[index];
    const rawPercent = Number(tariff?.commission);
    // 0% is a valid explicit value. Fallback is used only for invalid/missing values.
    const percent = Number.isFinite(rawPercent) && rawPercent >= 0 && rawPercent <= 100 ? rawPercent : 33.3;
    const price = this.safeNum(order.priceFinal || order.priceFrom, 0);
    const amount = Math.max(0, Math.round(price * (percent / 100)));
    return { percent, amount: Number.isFinite(amount) ? amount : 0 };
  }

  private async pushOrderIndex(key: string, orderId: string) {
    await this.redis.client.lpush(key, orderId);
    await this.redis.client.ltrim(key, 0, 99);
  }

  private async computePrice(input: CreateOrderInput) {
    const list = await this.loadTariffs();
    const index = this.safeNum(input.serviceIndex, 0);
    const tariff = list[index];
    const mode = tariff ? String(tariff.mode || '').trim().toLowerCase() : '';

    if (!tariff || mode !== 'custom') {
      const legacy = this.computeLegacyPrice(input);
      return {
        ...legacy,
        priceFrom: this.applyWeekendMarkup(legacy.priceFrom, tariff, input.scheduledAt),
      };
    }

    const base = this.safeNum(tariff.base);
    const perKm = this.safeNum(tariff.perKm);
    const perMin = this.safeNum(tariff.perMin);
    const includedMin = this.safeNum(tariff.includedMin);
    const distanceKm = Math.max(0, this.safeNum(input.routeDistanceMeters) / 1000);
    const minutes = this.routeMinutes(input.routeEtaSeconds);
    const extraMin = Math.max(0, minutes - includedMin);
    const priceFrom = Math.max(0, Math.round(base + perKm * distanceKm + perMin * extraMin));
    if (!Number.isFinite(priceFrom) || priceFrom <= 0) {
      const legacy = this.computeLegacyPrice(input);
      return {
        ...legacy,
        priceFrom: this.applyWeekendMarkup(legacy.priceFrom, tariff, input.scheduledAt),
      };
    }
    return {
      priceFrom: this.applyWeekendMarkup(priceFrom, tariff, input.scheduledAt),
      tariffName: String(tariff.name || ''),
    };
  }

  async createOrder(input: CreateOrderInput): Promise<Order> {
    const clientId = (input.clientId || '').trim();
    if (!clientId) throw new BadRequestException('clientId is required');
    const requestIdRaw = (input.requestId || '').toString().trim();
    const requestId = /^[a-zA-Z0-9_-]{8,64}$/.test(requestIdRaw) ? requestIdRaw : '';

    if (requestId) {
      const existingOrderId = await this.redis.client.get(this.orderRequestKey(clientId, requestId));
      if (existingOrderId) {
        try {
          const existingOrder = await this.getOrder(existingOrderId);
          if (existingOrder.clientId === clientId) {
            return existingOrder;
          }
        } catch {
          await this.redis.client.del(this.orderRequestKey(clientId, requestId));
        }
      }
    }

    let requestLockKey = '';
    if (requestId) {
      requestLockKey = this.orderRequestLockKey(clientId, requestId);
      const requestLockOk = await (this.redis.client as any).set(requestLockKey, '1', 'EX', 20, 'NX');
      if (!requestLockOk) {
        const orderId = await this.redis.client.get(this.orderRequestKey(clientId, requestId));
        if (orderId) {
          try {
            const order = await this.getOrder(orderId);
            if (order.clientId === clientId) return order;
          } catch {
            await this.redis.client.del(this.orderRequestKey(clientId, requestId));
          }
        }
        throw new ConflictException('Order create already in progress');
      }
    }

    try {
      const blocked = await this.redis.client.exists(`client:block:${clientId}`);
      if (blocked) throw new BadRequestException('Client is blocked');

      // Защита от дублей — нельзя создать заказ, если уже есть активный
      const existingActive = await this.findActiveOrderForClient(clientId);
      if (existingActive) {
        throw new ConflictException('Client already has an active order');
      }

      validatePoint(input.from, 'from');
      validatePoint(input.to, 'to');

      const id = crypto.randomUUID();
      const { priceFrom, tariffName } = await this.computePrice(input);

    // Скидка берётся только из серверного профиля клиента и сгорает после 1 заказа.
    let discountPercent = 0;
    const profileRaw = await this.redis.client.get(this.clientProfileKey(clientId));
    if (profileRaw) {
      try {
        const profile = JSON.parse(profileRaw) as Record<string, unknown>;
        discountPercent = Math.max(
          0,
          Math.min(100, Number((profile as any).promoDiscountPercent || 0)),
        );
        if (discountPercent > 0) {
          (profile as any).promoDiscountPercent = 0;
          (profile as any).promoCode = '';
          (profile as any).updatedAt = new Date().toISOString();
          await this.redis.client.set(this.clientProfileKey(clientId), JSON.stringify(profile));
        }
      } catch {
        discountPercent = 0;
      }
    }
    const priceAfterPromo = Math.round(priceFrom * (1 - Math.max(0, Math.min(100, discountPercent)) / 100));
    let bonusUsed = 0;
    const requestedBonus = Math.max(0, Math.round(Number(input.bonusAmount) || 0));
    if (requestedBonus > 0) {
      const bonusKey = this.clientBonusKey(clientId);
      const available = Number((await this.redis.client.hget(bonusKey, 'available')) || 0);
      if (requestedBonus > available) {
        throw new BadRequestException('Insufficient bonus balance');
      }
      if (requestedBonus > priceAfterPromo) {
        throw new BadRequestException('Bonus cannot exceed order price');
      }
      await this.redis.client.hincrby(bonusKey, 'available', -requestedBonus);
      bonusUsed = requestedBonus;
    }
    const order: Order = {
      id,
      clientId,
      from: input.from,
      to: input.to,
      fromAddress: input.fromAddress?.trim() ? input.fromAddress.trim() : undefined,
      toAddress: input.toAddress?.trim() ? input.toAddress.trim() : undefined,
      comment: input.comment?.trim() ? input.comment.trim() : undefined,
      wish: input.wish?.trim() ? input.wish.trim() : undefined,
      serviceIndex: Number.isFinite(Number(input.serviceIndex)) ? Number(input.serviceIndex) : undefined,
      priceFrom,
      promoDiscountPercent: discountPercent > 0 ? discountPercent : undefined,
      bonusUsed: bonusUsed > 0 ? bonusUsed : undefined,
      tariffName: tariffName || undefined,
      paymentMethod: input.paymentMethod === 'cash' ? 'cash' : 'sbp',
      paymentStatus: 'unpaid',
      routeDistanceMeters: Number.isFinite(Number(input.routeDistanceMeters))
        ? Number(input.routeDistanceMeters)
        : undefined,
      routeEtaSeconds: Number.isFinite(Number(input.routeEtaSeconds))
        ? Number(input.routeEtaSeconds)
        : undefined,
      kmOutsideMkad: Number.isFinite(Number(input.kmOutsideMkad))
        ? Number(input.kmOutsideMkad)
        : 0,
      scheduledAt: input.scheduledAt?.trim() ? input.scheduledAt.trim() : undefined,
      status: 'searching',
      createdAt: new Date().toISOString(),
    };

      await this.redis.client.set(this.orderKey(id), JSON.stringify(order), 'EX', 60 * 60 * 24 * 30);
      await this.markOrderSearching(id);
      await this.redis.client.lpush(this.recentListKey(), id);
      await this.redis.client.ltrim(this.recentListKey(), 0, 1999);
      await this.redis.client.sadd('clients:all', clientId);
      await this.pushOrderIndex(this.clientOrdersKey(clientId), id);
      if (requestId) {
        await this.redis.client.set(this.orderRequestKey(clientId, requestId), id, 'EX', 60 * 30);
      }
      return order;
    } finally {
      if (requestLockKey) {
        await this.redis.client.del(requestLockKey);
      }
    }
  }

  async getOrder(orderId: string): Promise<Order> {
    const raw = await this.redis.client.get(this.orderKey(orderId));
    if (!raw) throw new NotFoundException('Order not found');
    try {
      return JSON.parse(raw) as Order;
    } catch {
      throw new NotFoundException('Order data corrupted');
    }
  }

  async acceptOrder(orderId: string, driverPhone: string): Promise<Order> {
    const order = await this.getOrder(orderId);

    if (order.status !== 'searching') {
      throw new ConflictException('Order is not available');
    }

    if (await this.drivers.isBlocked(driverPhone)) {
      throw new ConflictException('DRIVER_BLOCKED');
    }

    // Проверка регистрации водителя
    const driverProfile = await this.drivers.getProfile(driverPhone);
    if (driverProfile && typeof driverProfile === 'object') {
      const regStatus = (driverProfile as any).registrationStatus || 'incomplete';
      if (regStatus !== 'completed') {
        throw new ConflictException('Driver registration not completed');
      }
    }

    // Проверка лимита заработка
    const earnings = await this.getDriverEarnings(driverPhone);
    const earningsLimit = Number(await this.redis.client.get('settings:earnings_limit') || 15000);
    if (Number(earnings.commission || 0) >= earningsLimit) {
      throw new ConflictException('EARNINGS_LIMIT_REACHED');
    }

    // Атомарный лок через SET NX — только один водитель пройдёт дальше
    const lockOk = await (this.redis.client as any).set(
      this.orderLockKey(orderId),
      driverPhone,
      'EX',
      30,
      'NX',
    );
    if (!lockOk) {
      throw new ConflictException('Order already taken');
    }

    try {
      // Перечитываем статус ПОСЛЕ получения лока — защита от race condition с cancelOrder
      const freshOrder = await this.getOrder(orderId);
      if (freshOrder.status !== 'searching') {
        throw new ConflictException('Order is not available');
      }

      const commission = await this.computeCommission(freshOrder);
      const next: Order = {
        ...freshOrder,
        status: 'accepted',
        driverPhone,
        commissionPercent: commission.percent,
        commissionAmount: commission.amount,
        acceptedAt: new Date().toISOString(),
      };

      await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
      await this.unmarkOrderSearching(orderId);

      // Определяем, является ли заказ предзаказом (scheduledAt > 15 мин в будущем)
      const isPreorder = freshOrder.scheduledAt
        ? new Date(freshOrder.scheduledAt).getTime() > Date.now() + 15 * 60 * 1000
        : false;

      if (isPreorder) {
        // Предзаказ — водитель остаётся online и может принимать другие заказы
        await this.drivers.setStatus(driverPhone, 'online');
        // НЕ добавляем в drivers:active_order — водитель свободен для новых заказов
      } else {
        // Обычный заказ — водитель busy
        await this.drivers.setStatus(driverPhone, 'busy');
        // Трекинг активного заказа водителя — O(1) проверка через SET
        await this.redis.client.sadd('drivers:active_order', driverPhone);
      }

      await this.pushOrderIndex(this.driverOrdersKey(driverPhone), orderId);
      // Заработок начисляется при ЗАВЕРШЕНИИ заказа, а не при принятии
      return next;
    } finally {
      // Гарантированно освобождаем лок
      await this.redis.client.del(this.orderLockKey(orderId));
    }
  }

  async declineOrder(orderId: string, driverPhone: string): Promise<void> {
    await this.getOrder(orderId);
    await this.redis.client.sadd(this.declineSetKey(orderId), driverPhone);
    await this.redis.client.expire(this.declineSetKey(orderId), 60 * 60);
  }

  async getDeclinedDrivers(orderId: string): Promise<Set<string>> {
    const phones = await this.redis.client.smembers(this.declineSetKey(orderId));
    return new Set((phones || []).map((phone) => String(phone || '').trim()).filter(Boolean));
  }

  async updateOrderStatus(orderId: string, driverPhone: string, status: OrderStatus): Promise<Order> {
    // Атомарный лок — защита от двойного начисления при повторных запросах
    const lockOk = await (this.redis.client as any).set(
      this.orderLockKey(orderId),
      'status_update',
      'EX',
      30,
      'NX',
    );
    if (!lockOk) {
      throw new ConflictException('Order update already in progress');
    }
    try {
      const order = await this.getOrder(orderId);
      if (order.driverPhone && order.driverPhone !== driverPhone) {
        throw new ConflictException('Driver mismatch');
      }
      if (!order.driverPhone) {
        throw new ConflictException('Order has no driver');
      }
      const allowedTransitions: Record<OrderStatus, OrderStatus[]> = {
        searching: ['accepted'],
        accepted: ['enroute', 'canceled'],
        enroute: ['arrived', 'canceled'],
        arrived: ['started', 'canceled'],
        started: ['completed', 'canceled'],
        completed: [],
        canceled: [],
      };
      const canMove = allowedTransitions[order.status]?.includes(status);
      if (!canMove) {
        throw new ConflictException('Invalid status transition');
      }
      const now = new Date().toISOString();
      const next: Order = {
        ...order,
        status,
        arrivedAt: status === 'arrived' ? now : order.arrivedAt,
        startedAt: status === 'started' ? now : order.startedAt,
        completedAt: status === 'completed' ? now : order.completedAt,
      };
      if (status === 'enroute' && !next.acceptedAt) {
        next.acceptedAt = now;
      }
      if (status === 'completed' && next.paymentMethod === 'cash') {
        next.paymentStatus = 'paid';
      }
      if (status === 'completed') {
        const finalPrice = await this.computeFinalPrice(next);
        if (finalPrice) {
          next.priceFinal = finalPrice.price;
          next.tripMinutes = finalPrice.minutes;
        }
      }
      await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
      if (order.status === 'searching' && status !== 'searching') {
        await this.unmarkOrderSearching(orderId);
      }
      // При переходе в enroute — водитель становится busy (важно для предзаказов)
      if (status === 'enroute' && order.driverPhone) {
        await this.drivers.setStatus(order.driverPhone, 'busy');
        await this.redis.client.sadd('drivers:active_order', order.driverPhone);
      }
      if (status === 'completed' && order.driverPhone) {
        await this.drivers.setStatus(order.driverPhone, 'online');
        await this.redis.client.srem('drivers:active_order', order.driverPhone);
        // Пересчитываем комиссию от финальной цены
        const price = Number(next.priceFinal || next.priceFrom || 0);
        if (Number.isFinite(price) && price > 0) {
          const commission = await this.computeCommission(next);
          const commAmount = Number.isFinite(commission.amount) ? commission.amount : 0;
          const safeComm = Math.min(commAmount, Math.round(price));
          const net = Math.round(price) - safeComm;
          // Обновляем комиссию в заказе
          next.commissionPercent = commission.percent;
          next.commissionAmount = safeComm;
          await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
          // Начисляем заработок
          await this.redis.client.hincrby(this.driverEarningsKey(order.driverPhone), 'gross', Math.round(price));
          await this.redis.client.hincrby(this.driverEarningsKey(order.driverPhone), 'commission', safeComm);
          await this.redis.client.hincrby(this.driverEarningsKey(order.driverPhone), 'net', net > 0 ? net : 0);
        }
      }
      if (status === 'canceled' && order.driverPhone) {
        await this.drivers.setStatus(order.driverPhone, 'online');
        await this.redis.client.srem('drivers:active_order', order.driverPhone);
      }
      return next;
    } finally {
      await this.redis.client.del(this.orderLockKey(orderId));
    }
  }

  async cancelOrder(orderId: string, clientId: string, reason?: string): Promise<Order> {
    const order = await this.getOrder(orderId);
    if (order.clientId !== clientId) {
      throw new BadRequestException('Client mismatch');
    }
    if (order.status === 'canceled' || order.status === 'completed') return order;

    // Лок для защиты от race condition с acceptOrder
    const lockOk = await (this.redis.client as any).set(
      this.orderLockKey(orderId),
      `cancel:${clientId}`,
      'EX',
      30,
      'NX',
    );
    if (!lockOk) {
      // Лок занят — водитель сейчас принимает заказ, перечитаем статус
      const fresh = await this.getOrder(orderId);
      if (fresh.status === 'canceled' || fresh.status === 'completed') return fresh;
      throw new ConflictException('Order is being processed, try again');
    }

    try {
      // Перечитываем статус ПОСЛЕ получения лока
      const freshOrder = await this.getOrder(orderId);
      if (freshOrder.clientId !== clientId) {
        throw new BadRequestException('Client mismatch');
      }
      if (freshOrder.status === 'canceled' || freshOrder.status === 'completed') return freshOrder;

      const next: Order = {
        ...freshOrder,
        status: 'canceled',
        cancelReason: reason?.trim() ? reason.trim() : freshOrder.cancelReason,
        canceledBy: 'client',
      };
      await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
      await this.unmarkOrderSearching(orderId);
      if (freshOrder.driverPhone) {
        await this.drivers.setStatus(freshOrder.driverPhone, 'online');
        await this.redis.client.srem('drivers:active_order', freshOrder.driverPhone);
      }
      return next;
    } finally {
      await this.redis.client.del(this.orderLockKey(orderId));
    }
  }

  async adminCancel(orderId: string, reason?: string): Promise<Order> {
    const order = await this.getOrder(orderId);
    if (order.status === 'canceled' || order.status === 'completed') return order;

    // Лок для защиты от race condition
    const lockOk = await (this.redis.client as any).set(
      this.orderLockKey(orderId),
      'cancel:admin',
      'EX',
      30,
      'NX',
    );
    if (!lockOk) {
      const fresh = await this.getOrder(orderId);
      if (fresh.status === 'canceled' || fresh.status === 'completed') return fresh;
      throw new ConflictException('Order is being processed, try again');
    }

    try {
      const freshOrder = await this.getOrder(orderId);
      if (freshOrder.status === 'canceled' || freshOrder.status === 'completed') return freshOrder;

      const next: Order = { ...freshOrder, status: 'canceled' };
      next.cancelReason = reason?.trim() ? reason.trim() : freshOrder.cancelReason;
      next.canceledBy = 'admin';
      await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
      await this.unmarkOrderSearching(orderId);
      if (freshOrder.driverPhone) {
        await this.drivers.setStatus(freshOrder.driverPhone, 'online');
        await this.redis.client.srem('drivers:active_order', freshOrder.driverPhone);
      }
      return next;
    } finally {
      await this.redis.client.del(this.orderLockKey(orderId));
    }
  }

  async listRecentOrders(limit = 50): Promise<Order[]> {
    const ids = await this.redis.client.lrange(this.recentListKey(), 0, Math.max(0, limit - 1));
    if (ids.length === 0) return [];
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    return raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order);
  }

  async findActiveOrderForDriver(phone: string): Promise<Order | null> {
    const ids = await this.redis.client.lrange(this.recentListKey(), 0, 199);
    if (!ids.length) return null;
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    const orders = raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order);
    return (
      orders.find(
        (o) =>
          o.driverPhone === phone &&
          (o.status === 'accepted' ||
            o.status === 'enroute' ||
            o.status === 'arrived' ||
            o.status === 'started'),
      ) || null
    );
  }

  async findActiveOrderForClient(clientId: string): Promise<Order | null> {
    const ids = await this.redis.client.lrange(this.recentListKey(), 0, 199);
    if (!ids.length) return null;
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    const orders = raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order)
      .filter(
        (o) =>
          o.clientId === clientId &&
          (o.status === 'searching' ||
            o.status === 'accepted' ||
            o.status === 'enroute' ||
            o.status === 'arrived' ||
            o.status === 'started'),
      );
    if (!orders.length) return null;
    orders.sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    return orders[0] || null;
  }

  private parseDateValue(value?: string, endOfDay = false) {
    if (!value) return undefined;
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return undefined;
    if (value.length === 10) {
      if (endOfDay) {
        date.setHours(23, 59, 59, 999);
      } else {
        date.setHours(0, 0, 0, 0);
      }
    }
    return date.getTime();
  }

  async listRecentOrdersFiltered(input: {
    limit?: number;
    status?: string;
    active?: boolean;
    paymentStatus?: string;
    clientId?: string;
    driverPhone?: string;
    from?: string;
    to?: string;
    priceMin?: number;
    priceMax?: number;
  }): Promise<Order[]> {
    const limit = Math.min(200, Math.max(1, input.limit || 50));
    const fetchLimit = Math.max(200, limit * 4);
    const ids = await this.redis.client.lrange(this.recentListKey(), 0, fetchLimit - 1);
    if (!ids.length) return [];
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    const orders = raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order);

    const status = (input.status || '').trim();
    const paymentStatus = (input.paymentStatus || '').trim();
    const clientId = (input.clientId || '').trim();
    const driverPhone = (input.driverPhone || '').trim();
    const fromTs = this.parseDateValue(input.from, false);
    const toTs = this.parseDateValue(input.to, true);
    const priceMin = Number.isFinite(Number(input.priceMin)) ? Number(input.priceMin) : undefined;
    const priceMax = Number.isFinite(Number(input.priceMax)) ? Number(input.priceMax) : undefined;

    const filtered = orders.filter((o) => {
      if (input.active) {
        if (!['searching', 'accepted', 'enroute', 'arrived', 'started'].includes(o.status)) return false;
      }
      if (status && o.status !== status) return false;
      if (paymentStatus && o.paymentStatus !== paymentStatus) return false;
      if (clientId && o.clientId !== clientId) return false;
      if (driverPhone && o.driverPhone !== driverPhone) return false;
      if (fromTs || toTs) {
        const ts = Date.parse(o.createdAt);
        if (Number.isNaN(ts)) return false;
        if (fromTs && ts < fromTs) return false;
        if (toTs && ts > toTs) return false;
      }
      if (priceMin != null) {
        const price = Number(o.priceFrom || 0);
        if (price < priceMin) return false;
      }
      if (priceMax != null) {
        const price = Number(o.priceFrom || 0);
        if (price > priceMax) return false;
      }
      return true;
    });

    return filtered.slice(0, limit);
  }

  async listOrdersForDriver(phone: string, limit = 50): Promise<Order[]> {
    const ids = await this.redis.client.lrange(this.driverOrdersKey(phone), 0, Math.max(0, limit - 1));
    if (!ids.length) {
      const fallback = await this.getAllOrdersForStats(2000);
      return fallback
        .filter((o) => (o.driverPhone || '').trim() === phone)
        .sort((a, b) => new Date(b.createdAt || 0).getTime() - new Date(a.createdAt || 0).getTime())
        .slice(0, limit);
    }
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    return raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order);
  }

  async listOrdersForClient(clientId: string, limit = 50): Promise<Order[]> {
    const ids = await this.redis.client.lrange(this.clientOrdersKey(clientId), 0, Math.max(0, limit - 1));
    if (!ids.length) {
      const fallback = await this.getAllOrdersForStats(2000);
      return fallback
        .filter((o) => (o.clientId || '').trim() === clientId)
        .sort((a, b) => new Date(b.createdAt || 0).getTime() - new Date(a.createdAt || 0).getTime())
        .slice(0, limit);
    }
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    return raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order);
  }

  async getClientOrderCount(clientId: string): Promise<number> {
    const n = await this.redis.client.llen(this.clientOrdersKey(clientId));
    return Number.isFinite(n) ? n : 0;
  }

  async findNearbySearchingOrderForDriver(phone: string, radiusKm = 2.5): Promise<Order | null> {
    const loc = await this.drivers.getLocation(phone);
    if (!loc) return null;
    const ids = await this.redis.client.lrange(this.recentListKey(), 0, 199);
    if (!ids.length) return null;
    const raws = await this.redis.client.mget(ids.map((id) => this.orderKey(id)));
    const orders = raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as Order)
      .filter((o) => o.status === 'searching');
    let best: Order | null = null;
    let bestDist = Number.POSITIVE_INFINITY;
    for (const o of orders) {
      const dist = this.distanceKm(loc, o.from);
      if (dist <= radiusKm && dist < bestDist) {
        bestDist = dist;
        best = o;
      }
    }
    return best;
  }

  async listPayouts(limit = 50, driverPhone?: string) {
    const ids = await this.redis.client.lrange(this.payoutsListKey(), 0, Math.max(0, limit - 1));
    if (!ids.length) return [];
    const raws = await this.redis.client.mget(ids.map((id) => this.payoutKey(id)));
    const payouts = raws
      .filter((raw): raw is string => typeof raw === 'string')
      .map((raw) => JSON.parse(raw) as any);
    if (!driverPhone) return payouts;
    return payouts.filter((p) => p?.driverPhone === driverPhone);
  }

  async assignDriver(orderId: string, driverPhone: string) {
    // Лок для защиты от race condition с acceptOrder
    const lockOk = await (this.redis.client as any).set(
      this.orderLockKey(orderId),
      'assign',
      'EX',
      30,
      'NX',
    );
    if (!lockOk) {
      throw new ConflictException('Order update already in progress');
    }
    try {
      const normalizedDriverPhone = (driverPhone || '').trim().replace(/\D/g, '');
      if (!normalizedDriverPhone) {
        throw new ConflictException('Driver phone required');
      }
      const order = await this.getOrder(orderId);
      if (order.status === 'canceled' || order.status === 'completed') {
        throw new ConflictException('Order is not available');
      }
      const driverProfile = await this.drivers.getProfile(normalizedDriverPhone);
      if (!driverProfile || typeof driverProfile !== 'object') {
        throw new ConflictException('Driver not found');
      }
      if ((driverProfile as any).registrationStatus !== 'completed') {
        throw new ConflictException('Driver registration not completed');
      }
      if (await this.drivers.isBlocked(normalizedDriverPhone)) {
        throw new ConflictException('Driver is blocked');
      }
      if (order.driverPhone && order.driverPhone === normalizedDriverPhone) return order;
      if (order.driverPhone && order.driverPhone !== normalizedDriverPhone) {
        await this.drivers.setStatus(order.driverPhone, 'online');
        await this.redis.client.srem('drivers:active_order', order.driverPhone);
      }
      const commission = await this.computeCommission(order);
      const next: Order = {
        ...order,
        status: 'accepted',
        driverPhone: normalizedDriverPhone,
        commissionPercent: commission.percent,
        commissionAmount: commission.amount,
        acceptedAt: new Date().toISOString(),
      };
      await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
      await this.unmarkOrderSearching(orderId);
      await this.drivers.setStatus(normalizedDriverPhone, 'busy');
      await this.pushOrderIndex(this.driverOrdersKey(normalizedDriverPhone), orderId);
      await this.redis.client.sadd('drivers:active_order', normalizedDriverPhone);
      return next;
    } finally {
      await this.redis.client.del(this.orderLockKey(orderId));
    }
  }

  async markPaid(orderId: string) {
    const order = await this.getOrder(orderId);
    if (order.paymentStatus === 'paid') return order;
    if (order.status !== 'completed') {
      throw new ConflictException('Only completed orders can be marked as paid');
    }
    const next: Order = {
      ...order,
      paymentStatus: 'paid',
    };
    await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);
    return next;
  }

  async createPayout(input: { driverPhone: string; amount: number; orderId?: string }) {
    const id = crypto.randomUUID();
    const payout = {
      id,
      driverPhone: input.driverPhone,
      amount: Math.round(Number(input.amount) || 0),
      orderId: input.orderId || undefined,
      createdAt: new Date().toISOString(),
      status: 'paid',
    };
    await this.redis.client.set(this.payoutKey(id), JSON.stringify(payout), 'EX', 60 * 60 * 24 * 365);
    await this.redis.client.lpush(this.payoutsListKey(), id);
    await this.redis.client.ltrim(this.payoutsListKey(), 0, 199);
    await this.redis.client.hincrby(this.driverEarningsKey(input.driverPhone), 'paid', payout.amount);
    return payout;
  }

  /** Откатить начисленный заработок при отмене заказа (не допускаем уход в минус) */
  private async rollbackEarnings(order: Order): Promise<void> {
    if (!order.driverPhone || !order.priceFrom) return;
    const gross = Math.round(Number(order.priceFrom) || 0);
    if (gross <= 0) return;
    const commissionAmount = Math.round(Number(order.commissionAmount) || 0);
    const net = gross - commissionAmount;
    // Читаем текущие значения чтобы не уйти в минус
    const current = await this.redis.client.hgetall(this.driverEarningsKey(order.driverPhone));
    const curGross = Number(current.gross || 0);
    const curCommission = Number(current.commission || 0);
    const curNet = Number(current.net || 0);
    // Вычитаем не больше чем есть
    const subGross = Math.min(gross, curGross);
    const subCommission = Math.min(commissionAmount, curCommission);
    const subNet = Math.min(net, curNet);
    if (subGross > 0) await this.redis.client.hincrby(this.driverEarningsKey(order.driverPhone), 'gross', -subGross);
    if (subCommission > 0) await this.redis.client.hincrby(this.driverEarningsKey(order.driverPhone), 'commission', -subCommission);
    if (subNet > 0) await this.redis.client.hincrby(this.driverEarningsKey(order.driverPhone), 'net', -subNet);
  }

  async getEarningsLimit(): Promise<number> {
    return Number(await this.redis.client.get('settings:earnings_limit') || 15000);
  }

  async getDriverEarnings(phone: string) {
    const raw = await this.redis.client.hgetall(this.driverEarningsKey(phone));
    const gross = this.safeNum(raw.gross);
    const commission = this.safeNum(raw.commission);
    const net = this.safeNum(raw.net);
    const paid = this.safeNum(raw.paid);
    return {
      gross,
      commission,
      net,
      paid,
      available: Math.max(0, net - paid),
    };
  }

  async getDriverStats(phone: string, limit = 200) {
    const orders = await this.listOrdersForDriver(phone, limit);
    let trips = 0;
    let acceptedOrders = 0;
    for (const o of orders) {
      if (o.status === 'canceled') continue; // не считаем отменённые
      acceptedOrders += 1;
      if (o.status === 'completed') trips += 1;
    }
    return { acceptedOrders, trips };
  }

  async getAllOrdersForStats(limit = 2000): Promise<Order[]> {
    const ids = await this.redis.client.lrange(this.recentListKey(), 0, Math.max(0, limit - 1));
    if (!ids.length) return [];
    // Fetch in batches to avoid huge mget
    const batchSize = 200;
    const orders: Order[] = [];
    for (let i = 0; i < ids.length; i += batchSize) {
      const batch = ids.slice(i, i + batchSize);
      const raws = await this.redis.client.mget(batch.map((id) => this.orderKey(id)));
      for (const raw of raws) {
        if (typeof raw === 'string') {
          try {
            orders.push(JSON.parse(raw) as Order);
          } catch {}
        }
      }
    }
    return orders;
  }

  async rateOrder(orderId: string, clientId: string, rating: number) {
    const order = await this.getOrder(orderId);
    if (order.clientId !== clientId) {
      throw new BadRequestException('Client mismatch');
    }
    if (order.status !== 'completed') {
      throw new ConflictException('Order not completed');
    }
    if (order.ratedAt) {
      throw new ConflictException('Order already rated');
    }
    const r = Math.max(1, Math.min(5, Math.round(rating)));
    const next: Order = {
      ...order,
      rating: r,
      ratedAt: new Date().toISOString(),
    };
    await this.redis.client.set(this.orderKey(orderId), JSON.stringify(next), 'EX', 60 * 60 * 24 * 30);

    if (order.driverPhone) {
      const key = this.driverRatingKey(order.driverPhone);
      const multi = this.redis.client.multi();
      multi.hincrby(key, 'sum', r);
      multi.hincrby(key, 'count', 1);
      const res = await multi.exec();
      const sum = Number(res?.[0]?.[1] || 0);
      const count = Number(res?.[1]?.[1] || 0);
      const avg = count > 0 ? Math.round((sum / count) * 10) / 10 : r;
      await this.redis.client.hset(key, 'avg', avg);
    }
    return next;
  }
}
