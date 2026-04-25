import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';
import { AuthController } from './auth.controller';
import { OtpService } from './otp.service';
import { RedisService } from './redis.service';
import { SmsService } from './sms.service';
import { EventsGateway } from './events.gateway';
import { OrdersController } from './orders.controller';
import { AdminController } from './admin.controller';
import { TariffsController } from './tariffs.controller';
import { OrdersService } from './orders.service';
import { DriversService } from './drivers.service';
import { DriversController } from './drivers.controller';
import { ClientsController } from './clients.controller';

@Module({
  imports: [],
  controllers: [HealthController, AuthController, OrdersController, AdminController, TariffsController, DriversController, ClientsController],
  providers: [RedisService, OtpService, SmsService, OrdersService, DriversService, EventsGateway],
})
export class AppModule {}
