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

/** Расширяющиеся радиусы поиска (метры) */
const SEARCH_RADII = [2000, 4000, 6000, 8000, 15000];
/** Задержка между раундами поиска (мс) */
const SEARCH_INTERVAL_MS = 12_000;
/** Автоотмена заказа если водитель не найден (мс) — 5 минут */
const AUTO_CANCEL_DELAY_MS = 5 * 60 * 1000;
/** Интервал очистки стухших Map-записей (мс) — 60 секунд */
const MAP_CLEANUP_INTERVAL_MS = 60_000;

@WebSocketGateway({ cors: { origin: '*' } })
export class EventsGateway implements OnGatewayConnection, OnGatewayDisconnect, OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(EventsGateway.name);
  constructor(
    private readonly orders: OrdersService,
    private readonly drivers: DriversService,
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

  onModuleInit() {
    // Запуск периодической очистки стухших записей в Maps
    this.cleanupInterval = setInterval(() => this.cleanupStaleMaps(), MAP_CLEANUP_INTERVAL_MS);
    this.logger.log('Map cleanup interval started (every 60s)');
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

  handleConnection(client: Socket) {
    const token =
      (client.handshake.auth && (client.handshake.auth as any).token) ||
      (typeof client.handshake.headers.authorization === 'string'
        ? client.handshake.headers.authorization.replace(/^Bearer\s+/i, '')
        : undefined);

    const clientIdRaw = (client.handshake.auth as any)?.clientId;
    const clientId = typeof clientIdRaw === 'string' ? clientIdRaw.trim() : '';

    const secret = process.env.JWT_SECRET;

    if (secret && token) {
      try {
        const payload = jwt.verify(token, secret) as any;
        (client.data as any).user = payload;
      } catch {
        client.disconnect(true);
        return;
      }
    } else if (clientId) {
      (client.data as any).clientId = clientId;
    } else {
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
    if (clientId) {
      client.join(`client:${clientId}`);
    }
  }

  handleDisconnect(client: Socket) {
    const user = (client.data as any).user as undefined | { phone?: string; role?: string };
    if (user?.role === 'driver' && typeof user.phone === 'string') {
      this.drivers.setStatus(user.phone, 'offline');
    }
  }

  // ─── Отправка заказа водителям ───────────────────────────────

  emitOrderNew(order: Order, driverPhones?: string[]) {
    if (driverPhones && driverPhones.length) {
      driverPhones.forEach((phone) => {
        this.server.to(`driver:${phone}`).emit('order:new', { order });
      });
      return;
    }
    this.server.to('drivers').emit('order:new', { order });
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

    let newDrivers: string[] = [];

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
        // O(1) проверка через Redis SET вместо LRANGE
        const hasActive = await this.drivers.hasActiveOrder(phone);
        if (hasActive) continue;
        const earnings = await this.orders.getDriverEarnings(phone);
        if (Number(earnings.net || 0) >= earningsLimit) continue;
        newDrivers.push(phone);
        notified.add(phone);
      }
    } else {
      // Финальный раунд — все онлайн водители
      const all = await this.drivers.listOnlineDrivers();
      for (const phone of all) {
        if (notified.has(phone)) continue;
        const hasActive = await this.drivers.hasActiveOrder(phone);
        if (hasActive) continue;
        const earnings = await this.orders.getDriverEarnings(phone);
        if (Number(earnings.net || 0) >= earningsLimit) continue;
        newDrivers.push(phone);
        notified.add(phone);
      }
    }

    // Отправляем заказ новым водителям
    if (newDrivers.length > 0) {
      this.emitOrderNew(order, newDrivers);
    }

    // Сообщение для клиента о ходе поиска
    if (roundIndex === 0 && newDrivers.length === 0) {
      this.emitOrderDelay(order, 'Ищем водителя поблизости…');
    } else if (roundIndex > 0 && roundIndex < SEARCH_RADII.length && newDrivers.length === 0) {
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
      if (order.driverPhone) {
        this.server.to(`driver:${order.driverPhone}`).emit('order:canceled', {
          orderId: order.id,
          reason: order.cancelReason || 'Клиент отменил заказ',
        });
      }
    }
  }

  // ─── Блокировка водителя ────────────────────────────────────

  emitDriverBlocked(phone: string) {
    this.server.to(`driver:${phone}`).emit('driver:blocked', { phone });
  }

  emitDriverUnblocked(phone: string) {
    this.server.to(`driver:${phone}`).emit('driver:unblocked', { phone });
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
      client.emit('driver:blocked', { phone: user.phone });
      await this.drivers.setStatus(user.phone, 'offline');
      return { ok: false, error: 'BLOCKED', blocked: true };
    }
    const status = body?.status;
    if (status !== 'online' && status !== 'offline' && status !== 'busy') {
      return { ok: false, error: 'invalid status' };
    }
    await this.drivers.setStatus(user.phone, status);
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
    const order = await this.orders.updateOrderStatus(orderId, user.phone.trim(), status as any);
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
