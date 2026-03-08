import { Body, Controller, Get, Headers, Param, Post, Query, UnauthorizedException } from '@nestjs/common';
import { EventsGateway } from './events.gateway';
import { DriversService } from './drivers.service';
import { CreateOrderInput, OrdersService } from './orders.service';
import jwt from 'jsonwebtoken';

@Controller('orders')
export class OrdersController {
  constructor(
    private readonly orders: OrdersService,
    private readonly events: EventsGateway,
    private readonly drivers: DriversService,
  ) {}

  private verifyToken(auth?: string) {
    const token = auth?.replace(/^Bearer\s+/i, '').trim();
    if (!token) throw new UnauthorizedException('Authorization required');
    const secret = process.env.JWT_SECRET;
    if (!secret) throw new UnauthorizedException('Server configuration error');
    try {
      return jwt.verify(token, secret) as any;
    } catch {
      throw new UnauthorizedException('Invalid token');
    }
  }

  private requireAdmin(auth?: string) {
    const payload = this.verifyToken(auth);
    if (!payload || payload.role !== 'admin') {
      throw new UnauthorizedException('Admin token required');
    }
    return payload;
  }

  private requireClientId(auth?: string) {
    const payload = this.verifyToken(auth);
    if (!payload || payload.role !== 'client' || typeof payload.phone !== 'string' || !payload.phone.trim()) {
      throw new UnauthorizedException('Client token required');
    }
    return payload.phone.trim();
  }

  private requireDriverPhone(auth?: string) {
    const payload = this.verifyToken(auth);
    if (!payload || payload.role !== 'driver' || typeof payload.phone !== 'string' || !payload.phone.trim()) {
      throw new UnauthorizedException('Driver token required');
    }
    return payload.phone.trim();
  }

  @Post()
  async create(@Body() body: CreateOrderInput, @Headers('authorization') auth?: string) {
    const clientId = this.requireClientId(auth);
    const order = await this.orders.createOrder({
      ...body,
      clientId,
    });
    // Запускаем расширяющийся поиск водителей (2→4→6→8→15→all км)
    this.events.startExpandingSearch(order);
    return { ok: true, order };
  }

  @Get(':id')
  async get(@Param('id') id: string, @Headers('authorization') auth?: string) {
    const order = await this.orders.getOrder(id);
    const payload = this.verifyToken(auth);
    if (payload?.role === 'client') {
      const clientId = String(payload.phone || '').trim();
      if (!clientId || order.clientId !== clientId) {
        throw new UnauthorizedException('Access denied');
      }
    } else if (payload?.role === 'driver') {
      const phone = String(payload.phone || '').trim();
      if (!phone || order.driverPhone !== phone) {
        throw new UnauthorizedException('Access denied');
      }
    } else if (payload?.role !== 'admin') {
      throw new UnauthorizedException('Access denied');
    }
    // Добавляем координаты водителя если заказ активный
    let driverLat: number | null = null;
    let driverLng: number | null = null;
    if (order && order.driverPhone) {
      const loc = await this.drivers.getLocation(order.driverPhone);
      if (loc) {
        driverLat = loc.lat;
        driverLng = loc.lng;
      }
    }
    return { ok: true, order, driverLat, driverLng };
  }

  @Get('active/client')
  async getActiveForClient(@Headers('authorization') auth?: string) {
    const clientId = this.requireClientId(auth);
    const order = await this.orders.findActiveOrderForClient(clientId);
    let driverLat: number | null = null;
    let driverLng: number | null = null;
    if (order && order.driverPhone) {
      const loc = await this.drivers.getLocation(order.driverPhone);
      if (loc) {
        driverLat = loc.lat;
        driverLng = loc.lng;
      }
    }
    return { ok: true, order, driverLat, driverLng };
  }

  @Get('active/driver')
  async getActiveForDriver(@Headers('authorization') auth?: string) {
    const phone = this.requireDriverPhone(auth);
    const order = await this.orders.findActiveOrderForDriver(phone);
    return { ok: true, order };
  }

  @Post(':id/cancel')
  async cancel(
    @Param('id') id: string,
    @Body() body: { clientId?: string; reason?: string },
    @Headers('authorization') auth?: string,
  ) {
    const clientId = this.requireClientId(auth);
    const order = await this.orders.cancelOrder(id, clientId, body?.reason);
    this.events.emitOrderStatus(order);
    return { ok: true, order };
  }

  @Post(':id/pay')
  async pay(@Param('id') id: string, @Headers('authorization') auth?: string) {
    this.requireAdmin(auth);
    const order = await this.orders.markPaid(id);
    return { ok: true, order };
  }

  @Post(':id/rate')
  async rate(
    @Param('id') id: string,
    @Body() body: { clientId?: string; rating?: number },
    @Headers('authorization') auth?: string,
  ) {
    const clientId = this.requireClientId(auth);
    const rating = Number(body?.rating || 0);
    const order = await this.orders.rateOrder(id, clientId, rating);
    return { ok: true, order };
  }

  @Get()
  async list(
    @Query('limit') limitRaw?: string,
    @Query('status') status?: string,
    @Query('active') active?: string,
    @Query('paymentStatus') paymentStatus?: string,
    @Query('clientId') clientId?: string,
    @Query('driverPhone') driverPhone?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('priceMin') priceMin?: string,
    @Query('priceMax') priceMax?: string,
    @Headers('authorization') auth?: string,
  ) {
    this.requireAdmin(auth);
    const limit = Math.min(200, Math.max(1, Number(limitRaw) || 50));
    const orders = await this.orders.listRecentOrdersFiltered({
      limit,
      status,
      active: active === '1' || active === 'true',
      paymentStatus,
      clientId,
      driverPhone,
      from,
      to,
      priceMin: priceMin ? Number(priceMin) : undefined,
      priceMax: priceMax ? Number(priceMax) : undefined,
    });
    return { ok: true, orders };
  }
}
