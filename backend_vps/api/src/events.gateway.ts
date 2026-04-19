import {
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import jwt from 'jsonwebtoken';

import { Order, OrdersService } from './orders.service';
import { DriversService } from './drivers.service';
import { RedisService } from './redis.service';

/** Расширяющиеся радиусы поиска (метры) */
const SEARCH_RADII = [2000, 4000, 6000, 8000, 15000];
/** Задержка между раундами поиска (мс) */
const SEARCH_INTERVAL_MS = 10_000;
/** Автоотмена заказа если водитель не найден (мс) — 5 минут */
const AUTO_CANCEL_DELAY_MS = 5 * 60 * 1000;
/** Интервал очистки стухших Map-записей (мс) — 60 секунд */
const MAP_CLEANUP_INTERVAL_MS = 60_000;

@WebSocketGateway({
  cors: {
    origin: true,
    credentials: true,
  },
})
export class EventsGateway implements OnGatewayConnection, OnGatewayDisconnect, OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(EventsGateway.name);
  constructor(
    private readonly orders: OrdersService,
    private readonly drivers: DriversService,
    private readonly redis: RedisService,
  ) {}

  @WebSocketServer()
  server!: Server;

  /** Активные таймеры расширяющегося поиска: orderId → timerId */
  private searchTimers = new Map<string, ReturnType<typeof setTimeout>>();
  /** Множество уже уведомлённых водителей по заказу */
  private notifiedDrivers = new Map<string, Set<string>>();
  /** Таймеры автоотмены заказов (когда водитель не найден) */
  private autoCancelTimers = new Map<string, ReturnType<typeof setTimeout>>();
  /** Интервал периодической очистки Maps */
  private cleanupInterval: ReturnType<typeof setInterval> | null = null;

  private notifiedSetKey(orderId: string) {
    return `order:notified:${orderId}`;
  }

  async onModuleInit() {
    // Запуск периодической очистки стухших записей в Maps
    this.cleanupInterval = setInterval(() => this.cleanupStaleMaps(), MAP_CLEANUP_INTERVAL_MS);
    this.logger.log('Map cleanup interval started (every 60s)');
    await this.restoreSearchingOrders();
  }

  onModuleDestroy() {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
      this.cleanupInterval = null;
    }
    // Очищаем все таймеры
    for (const timer of this.searchTimers.values()) clearTimeout(timer);
    this.searchTimers.clear();
    for (const timer of this.autoCancelTimers.values()) clearTimeout(timer);
    this.autoCancelTimers.clear();
    this.notifiedDrivers.clear();
  }

  /** Периодическая очистка: если заказ больше не в searching, удаляем из Maps */
  private async cleanupStaleMaps() {
    const orderIds = new Set([
      ...this.searchTimers.keys(),
      ...this.notifiedDrivers.keys(),
      ...this.autoCancelTimers.keys(),
    ]);
    if (orderIds.size === 0) return;

    let cleaned = 0;
    for (const orderId of orderIds) {
      try {
        const order = await this.orders.getOrder(orderId);
        if (order.status !== 'searching') {
          this.stopExpandingSearch(orderId);
          this.stopAutoCancel(orderId);
          cleaned++;
        }
      } catch {
        // Заказ не найден — тоже очищаем
        this.stopExpandingSearch(orderId);
        this.stopAutoCancel(orderId);
        cleaned++;
      }
    }
    if (cleaned > 0) {
      this.logger.log(`Map cleanup: removed ${cleaned} stale entries`);
    }
  }

  private async restoreSearchingOrders() {
    try {
      const searchingIds = await this.orders.listSearchingOrderIds();
      const activeSearches: Order[] = [];
      for (const orderId of searchingIds) {
        try {
          const order = await this.orders.getOrder(orderId);
          if (order.status === 'searching') {
            activeSearches.push(order);
          } else {
            await this.orders.unmarkOrderSearching(orderId);
          }
        } catch {
          await this.orders.unmarkOrderSearching(orderId);
        }
      }
      if (!activeSearches.length) return;
      activeSearches.forEach((order) => this.startExpandingSearch(order));
      this.logger.log(`Restored ${activeSearches.length} searching orders after restart`);
    } catch (err) {
      this.logger.warn(`Failed to restore searching orders: ${err}`);
    }
  }

  private async retrySearchingOrdersForDriver(phone: string) {
    for (const [orderId, notified] of this.notifiedDrivers.entries()) {
      if (!notified.has(phone)) continue;
      try {
        const order = await this.orders.getOrder(orderId);
        if (order.status !== 'searching') continue;
        this.stopExpandingSearch(orderId);
        this.notifiedDrivers.set(orderId, notified);
        await this.runSearchRound(order, 0, notified);
      } catch (err) {
        this.logger.warn(`Failed to retry searching order ${orderId} after driver disconnect ${phone}: ${err}`);
      }
    }
  }

  private async deliverNearbySearchingOrderToDriver(phone: string) {
    try {
      const nearby = await this.orders.findNearbySearchingOrderForDriver(phone, 8);
      if (nearby) {
        this.server.to(`driver:${phone}`).emit('order:nearby', { order: nearby });
      }
    } catch (err) {
      this.logger.warn(`Failed to deliver nearby searching order to ${phone}: ${err}`);
    }
  }

  handleConnection(client: Socket) {
    const token =
      (client.handshake.auth && (client.handshake.auth as any).token) ||
      (typeof client.handshake.headers.authorization === 'string'
        ? client.handshake.headers.authorization.replace(/^Bearer\s+/i, '')
        : undefined);
    const secret = process.env.JWT_SECRET;
    if (!secret || !token) {
      this.logger.warn(`Socket rejected: missing auth token from ${client.handshake.address}`);
      client.disconnect(true);
      return;
    }
    try {
      const payload = jwt.verify(token, secret) as any;
      (client.data as any).user = payload;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.logger.warn(`Socket rejected: invalid token from ${client.handshake.address}: ${message}`);
      client.disconnect(true);
      return;
    }

    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (user?.role === 'driver') {
      if (user.phone) {
        client.join(`driver:${user.phone}`);
        this.drivers.setStatus(user.phone, 'online');
      }
      client.join('drivers');
      return;
    }
    if (user?.role === 'client' && typeof user.phone === 'string' && user.phone.trim()) {
      client.join(`client:${user.phone.trim()}`);
      return;
    }
    this.logger.warn(`Socket rejected: unsupported role from ${client.handshake.address}`);
    client.disconnect(true);
  }

  handleDisconnect(client: Socket) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (user?.role === 'driver' && typeof user.phone === 'string') {
      this.drivers.setStatus(user.phone, 'offline');
    }
  }

  // ─── Отправка заказа водителям ───────────────────────────────

  private hasLiveDriverSocket(phone: string): boolean {
    const room = this.server.sockets.adapter.rooms.get(`driver:${phone}`);
    return Boolean(room && room.size > 0);
  }

  emitOrderNew(order: Order, driverPhones?: string[]): string[] {
    if (driverPhones && driverPhones.length) {
      const delivered: string[] = [];
      driverPhones.forEach((phone) => {
        if (!this.hasLiveDriverSocket(phone)) return;
        this.server.to(`driver:${phone}`).emit('order:new', {
          order,
          notifiedAt: new Date().toISOString(),
        });
        delivered.push(phone);
      });
      return delivered;
    }
    this.server.to('drivers').emit('order:new', {
      order,
      notifiedAt: new Date().toISOString(),
    });
    return [];
  }

  // ─── Расширяющийся поиск водителей ──────────────────────────

  /**
   * Запускает каскадный поиск: сначала ближайшие водители,
   * если никто не принял — расширяем радиус, и так до "все онлайн".
   */
  startExpandingSearch(order: Order) {
    // Очищаем предыдущий поиск для этого заказа если был
    this.stopExpandingSearch(order.id);
    const notified = new Set<string>();
    this.notifiedDrivers.set(order.id, notified);

    // Запускаем первый раунд немедленно
    this.runSearchRound(order, 0, notified);
  }

  stopExpandingSearch(orderId: string) {
    const timer = this.searchTimers.get(orderId);
    if (timer) {
      clearTimeout(timer);
      this.searchTimers.delete(orderId);
    }
    this.notifiedDrivers.delete(orderId);
  }

  /** Запуск таймера автоотмены заказа через 5 минут */
  private startAutoCancel(order: Order) {
    this.stopAutoCancel(order.id);
    const timer = setTimeout(async () => {
      this.autoCancelTimers.delete(order.id);
      try {
        const current = await this.orders.getOrder(order.id);
        if (current.status !== 'searching') return;
        // Автоотмена — водитель не найден
        const canceled = await this.orders.adminCancel(order.id, 'Водитель не найден');
        this.emitOrderStatus(canceled);
        this.emitOrderDelay(order, 'К сожалению, свободных водителей не найдено. Попробуйте позже.');
        this.logger.log(`Auto-canceled order ${order.id} — no driver found`);
      } catch (err) {
        this.logger.warn(`Auto-cancel failed for order ${order.id}: ${err}`);
      }
    }, AUTO_CANCEL_DELAY_MS);
    this.autoCancelTimers.set(order.id, timer);
  }

  stopAutoCancel(orderId: string) {
    const timer = this.autoCancelTimers.get(orderId);
    if (timer) {
      clearTimeout(timer);
      this.autoCancelTimers.delete(orderId);
    }
  }

  private async runSearchRound(order: Order, roundIndex: number, notified: Set<string>) {
    try {
      const persisted = await this.redis.client.smembers(this.notifiedSetKey(order.id));
      (persisted || []).forEach((phone: string) => {
        const p = String(phone || '').trim();
        if (p) notified.add(p);
      });
    } catch {
      // ignore redis issues, in-memory dedupe still works within process lifetime
    }

    // Проверяем актуальность заказа
    try {
      const current = await this.orders.getOrder(order.id);
      if (current.status !== 'searching') {
        this.stopExpandingSearch(order.id);
        return;
      }
    } catch {
      this.stopExpandingSearch(order.id);
      return;
    }

    let candidateDrivers: string[] = [];
    const declinedDrivers = await this.orders.getDeclinedDrivers(order.id);

    // Лимит заработка — не отправляем заказ водителям с достигнутым лимитом
    const earningsLimit = Number(
      (await this.orders.getEarningsLimit()) || 15000,
    );

    if (roundIndex < SEARCH_RADII.length) {
      const radius = SEARCH_RADII[roundIndex];
      const nearby = await this.drivers.getNearbyDrivers(
        order.from.lat,
        order.from.lng,
        radius,
        200,
      );
      // Фильтруем: только ещё не уведомлённые, без активных заказов и без лимита
      for (const phone of nearby) {
        if (notified.has(phone)) continue;
        if (declinedDrivers.has(phone)) continue;
        // O(1) проверка через Redis SET вместо LRANGE
        const hasActive = await this.drivers.hasActiveOrder(phone);
        if (hasActive) continue;
        const earnings = await this.orders.getDriverEarnings(phone);
        if (Number(earnings.commission || 0) >= earningsLimit) continue;
        candidateDrivers.push(phone);
      }
    } else {
      // Финальный раунд — все онлайн водители
      const all = await this.drivers.listOnlineDrivers();
      for (const phone of all) {
        if (notified.has(phone)) continue;
        if (declinedDrivers.has(phone)) continue;
        const hasActive = await this.drivers.hasActiveOrder(phone);
        if (hasActive) continue;
        const earnings = await this.orders.getDriverEarnings(phone);
        if (Number(earnings.commission || 0) >= earningsLimit) continue;
        candidateDrivers.push(phone);
      }
    }

    // Отправляем заказ только реально подключенным водителям.
    // В notified попадают только те, кто действительно получил событие.
    let deliveredDrivers: string[] = [];
    if (candidateDrivers.length > 0) {
      deliveredDrivers = this.emitOrderNew(order, candidateDrivers);
      deliveredDrivers.forEach((phone) => notified.add(phone));
      if (deliveredDrivers.length) {
        await this.redis.client.sadd(this.notifiedSetKey(order.id), ...deliveredDrivers);
        await this.redis.client.expire(this.notifiedSetKey(order.id), 60 * 60 * 2);
      }

      // Чистим "зависшие online" статусы (ключ есть, но сокета уже нет),
      // чтобы заказ не терялся на фальшиво-онлайн водителях.
      const undelivered = candidateDrivers.filter((p) => !deliveredDrivers.includes(p));
      if (undelivered.length) {
        await Promise.all(
          undelivered.map((phone) => this.drivers.setStatus(phone, 'offline')),
        );
      }
    }

    // Сообщение для клиента о ходе поиска
    if (roundIndex === 0 && deliveredDrivers.length === 0) {
      this.emitOrderDelay(order, 'Ищем водителя поблизости…');
    } else if (roundIndex > 0 && roundIndex < SEARCH_RADII.length && deliveredDrivers.length === 0) {
      this.emitOrderDelay(order, 'Расширяем зону поиска…');
    }

    // Планируем следующий раунд если ещё есть куда расширять
    if (roundIndex <= SEARCH_RADII.length) {
      const timer = setTimeout(() => {
        this.runSearchRound(order, roundIndex + 1, notified);
      }, SEARCH_INTERVAL_MS);
      this.searchTimers.set(order.id, timer);
    } else {
      // Все раунды завершены — запуск таймера автоотмены через 5 минут
      this.emitOrderDelay(order, 'Ожидайте, все водители получили ваш заказ.');
      this.stopExpandingSearch(order.id);
      this.startAutoCancel(order);
    }
  }

  // ─── Уведомления о статусе ──────────────────────────────────

  emitOrderStatus(order: Order) {
    this.server.to(`client:${order.clientId}`).emit('order:status', {
      orderId: order.id,
      status: order.status,
      driverPhone: order.driverPhone,
    });
    this.server.to('drivers').emit('order:status', {
      orderId: order.id,
      status: order.status,
      driverPhone: order.driverPhone,
    });

    // Если заказ принят — остановить поиск + автоотмену + уведомить конкретного водителя
    if (order.status === 'accepted' && order.driverPhone) {
      this.stopExpandingSearch(order.id);
      this.stopAutoCancel(order.id);
      void this.redis.client.del(this.notifiedSetKey(order.id));
      // Дополнительно — отправить order:taken всем водителям чтобы убрали заказ с экрана
      this.server.to('drivers').emit('order:taken', {
        orderId: order.id,
        driverPhone: order.driverPhone,
      });
    }

    // Если заказ отменён — остановить поиск + автоотмену + уведомить конкретного водителя
    if (order.status === 'canceled') {
      this.stopExpandingSearch(order.id);
      this.stopAutoCancel(order.id);
      void this.redis.client.del(this.notifiedSetKey(order.id));
      if (order.driverPhone) {
        this.server.to(`driver:${order.driverPhone}`).emit('order:canceled', {
          orderId: order.id,
          reason: order.cancelReason || 'Клиент отменил заказ',
        });
      }
    }
  }

  // ─── Блокировка водителя ────────────────────────────────────

  emitDriverBlocked(phone: string, payload?: { reason?: string; until?: string | null }) {
    this.server.to(`driver:${phone}`).emit('driver:blocked', {
      phone,
      reason: payload?.reason || 'manual',
      until: payload?.until || null,
    });
  }

  emitDriverUnblocked(phone: string) {
    this.server.to(`driver:${phone}`).emit('driver:unblocked', { phone });
  }

  emitDriverSubscriptionOverdue(phone: string) {
    this.server.to(`driver:${phone}`).emit('driver:subscription_overdue', { phone });
  }

  emitDriverSubscriptionPaid(phone: string) {
    this.server.to(`driver:${phone}`).emit('driver:subscription_paid', { phone });
  }

  /** Комиссия погашена — водитель снова может принимать заказы */
  emitCommissionCleared(phone: string) {
    this.server.to(`driver:${phone}`).emit('commission:cleared', { phone });
  }

  emitOrderDelay(order: Order, message: string) {
    this.server.to(`client:${order.clientId}`).emit('order:delay', {
      orderId: order.id,
      message,
    });
  }

  // ─── Обработчики сообщений от водителей ─────────────────────

  @SubscribeMessage('driver:location')
  async driverLocation(
    @ConnectedSocket() client: Socket,
    @MessageBody() body: { lat?: number; lng?: number },
  ) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (!user || user.role !== 'driver' || typeof user.phone !== 'string') {
      return { ok: false, error: 'UNAUTHORIZED' };
    }
    const lat = Number(body?.lat);
    const lng = Number(body?.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      return { ok: false, error: 'invalid coords' };
    }
    await this.drivers.updateLocation(user.phone, lat, lng);
    const active = await this.orders.findActiveOrderForDriver(user.phone);
    if (active) {
      this.server.to(`client:${active.clientId}`).emit('driver:location', {
        orderId: active.id,
        driverPhone: user.phone,
        status: active.status,
        lat,
        lng,
      });
    }
    return { ok: true };
  }

  @SubscribeMessage('driver:status')
  async driverStatus(
    @ConnectedSocket() client: Socket,
    @MessageBody() body: { status?: 'online' | 'offline' | 'busy' },
  ) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (!user || user.role !== 'driver' || typeof user.phone !== 'string') {
      return { ok: false, error: 'UNAUTHORIZED' };
    }
    // Проверяем блокировку
    const isBlocked = await this.drivers.isBlocked(user.phone);
    if (isBlocked) {
      const meta = await this.drivers.getBlockMeta(user.phone);
      client.emit('driver:blocked', {
        phone: user.phone,
        reason: meta?.reason || 'manual',
        until: meta?.until || null,
      });
      await this.drivers.setStatus(user.phone, 'offline');
      return { ok: false, error: 'BLOCKED', blocked: true };
    }
    const status = body?.status;
    if (status !== 'online' && status !== 'offline' && status !== 'busy') {
      return { ok: false, error: 'invalid status' };
    }
    if (status === 'online') {
      const earnings = await this.orders.getDriverEarnings(user.phone);
      const earningsLimit = await this.orders.getEarningsLimit();
      const commission = Number(earnings.commission || 0);
      if (commission >= earningsLimit) {
        await this.drivers.setStatus(user.phone, 'offline');
        client.emit('driver:earnings-limit', {
          phone: user.phone,
          commission,
          limit: earningsLimit,
        });
        return {
          ok: false,
          error: 'EARNINGS_LIMIT_REACHED',
          commission,
          limit: earningsLimit,
        };
      }
      const subOverdue = await this.drivers.isSubscriptionOverdue(user.phone);
      const hasActiveOrder = await this.drivers.hasActiveOrder(user.phone);
      if (subOverdue && !hasActiveOrder) {
        await this.drivers.setStatus(user.phone, 'offline');
        client.emit('driver:subscription_overdue', { phone: user.phone });
        return { ok: false, error: 'SUBSCRIPTION_OVERDUE' };
      }
    }
    await this.drivers.setStatus(user.phone, status);
    if (status === 'online') {
      void this.retrySearchingOrdersForDriver(user.phone);
      void this.deliverNearbySearchingOrderToDriver(user.phone);
    }
    return { ok: true };
  }

  @SubscribeMessage('order:accept')
  async accept(
    @ConnectedSocket() client: Socket,
    @MessageBody() body: { orderId?: string },
  ) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (!user || user.role !== 'driver' || typeof user.phone !== 'string' || !user.phone.trim()) {
      return { ok: false, error: 'UNAUTHORIZED' };
    }
    const orderId = (body?.orderId || '').trim();
    if (!orderId) return { ok: false, error: 'orderId required' };

    try {
      const order = await this.orders.acceptOrder(orderId, user.phone.trim());
      this.emitOrderStatus(order);
      return { ok: true, order };
    } catch (err: any) {
      const message = err?.message || err?.response?.message || 'Order already taken';
      if (message === 'DRIVER_BLOCKED') {
        const meta = await this.drivers.getBlockMeta(user.phone.trim());
        client.emit('driver:blocked', {
          phone: user.phone.trim(),
          reason: meta?.reason || 'manual',
          until: meta?.until || null,
        });
        return { ok: false, error: 'DRIVER_BLOCKED', message };
      }
      // Лимит заработка — отдельный код ошибки для водителя
      if (message === 'EARNINGS_LIMIT_REACHED') {
        return { ok: false, error: 'EARNINGS_LIMIT_REACHED', message };
      }
      // Race condition — заказ уже принят другим водителем
      return { ok: false, error: 'ORDER_TAKEN', message };
    }
  }

  @SubscribeMessage('order:decline')
  async decline(
    @ConnectedSocket() client: Socket,
    @MessageBody() body: { orderId?: string },
  ) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (!user || user.role !== 'driver' || typeof user.phone !== 'string' || !user.phone.trim()) {
      return { ok: false, error: 'UNAUTHORIZED' };
    }
    const orderId = (body?.orderId || '').trim();
    if (!orderId) return { ok: false, error: 'orderId required' };

    await this.orders.declineOrder(orderId, user.phone.trim());
    const strike = await this.drivers.registerMissedOrder(user.phone.trim());
    if (strike.blocked) {
      client.emit('driver:blocked', {
        phone: user.phone.trim(),
        reason: 'missed_orders',
        until: strike.until || null,
      });
    }
    try {
      const order = await this.orders.getOrder(orderId);
      if (order.status === 'searching') {
        const existing = this.notifiedDrivers.get(order.id) ?? new Set<string>();
        this.stopExpandingSearch(order.id);
        this.notifiedDrivers.set(order.id, existing);
        await this.runSearchRound(order, 0, existing);
      }
    } catch (err) {
      this.logger.warn(`Failed to continue search for declined order ${orderId}: ${err}`);
    }
    return { ok: true };
  }

  @SubscribeMessage('order:update')
  async update(
    @ConnectedSocket() client: Socket,
    @MessageBody() body: { orderId?: string; status?: string },
  ) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (!user || user.role !== 'driver' || typeof user.phone !== 'string' || !user.phone.trim()) {
      return { ok: false, error: 'UNAUTHORIZED' };
    }
    const orderId = (body?.orderId || '').trim();
    const status = (body?.status || '').trim();
    if (!orderId || !status) return { ok: false, error: 'orderId and status required' };
    let order: Order;
    try {
      order = await this.orders.updateOrderStatus(orderId, user.phone.trim(), status as any);
    } catch (err: any) {
      return { ok: false, error: err?.message || 'UPDATE_FAILED' };
    }
    this.emitOrderStatus(order);
    if (order.status === 'completed') {
      const nearby = await this.orders.findNearbySearchingOrderForDriver(user.phone.trim(), 2.5);
      if (nearby) {
        this.server.to(`driver:${user.phone.trim()}`).emit('order:nearby', { order: nearby });
      }
    }
    return { ok: true, order };
  }
}
