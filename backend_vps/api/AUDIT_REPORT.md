# Taxi App Backend — Code Audit Report

**Scope:** `events.gateway.ts`, `admin.controller.ts`, `auth.controller.ts`, `clients.controller.ts`, `drivers.service.ts`  
**Focus:** Auth bypass, sockets, race conditions, rate limiting, validation, admin security, driver status, crash risks.

---

## 1. Authentication bypass vulnerabilities

### 1.1 **CRITICAL: Client endpoints have no authentication**

**File:** `clients.controller.ts`  
**Endpoints:** `GET /client/profile`, `POST /client/profile`, `POST /client/bonus/use`, `POST /client/promo/activate`

**Issue:** Any caller can pass any `clientId` (or `id`) and read/update profiles, use bonuses, or activate promos. There is no JWT or session check; the only “auth” is the client-supplied `clientId`.

**Lines:** 24–26 (getProfile), 43–53 (saveProfile), 86–100 (useBonus), 103–133 (activatePromo)

**Fix:** Require authentication (e.g. JWT or session) and bind `clientId` to the authenticated user. Do not trust `clientId` from the body/query alone.

---

### 1.2 **WebSocket: Unauthenticated client connections allowed with arbitrary `clientId`**

**File:** `events.gateway.ts`  
**Lines:** 94–119, 134–136

**Issue:** Connection is allowed if **either** a valid JWT **or** a non-empty `clientId` in handshake auth is present. When only `clientId` is sent (no token), the client is not verified; any string is accepted. That client can then join `client:${clientId}` and receive order events (e.g. `order:status`, `order:delay`) for that ID.

**Fix:** Require a verified identity for client connections (e.g. JWT with role `client` and a stable client id, or a signed token that includes `clientId`). Do not allow “auth by arbitrary clientId string”.

---

### 1.3 **Admin endpoints**

**File:** `admin.controller.ts`  
**Lines:** 35–44 (`requireAdmin`), used on all admin routes

**Finding:** Admin routes consistently call `requireAdmin(auth)` and check `payload.role === 'admin'`. No auth bypass found for admin endpoints.

---

## 2. Socket events — validation, naming, error handling

### 2.1 **Missing input validation on socket payloads**

**File:** `events.gateway.ts`

- **`driver:location`** (353–358): `body?.lat` and `body?.lng` are only checked with `Number.isFinite()`. No check that `body` is a non-null object; no length/size limit on payload.  
  **Fix:** Ensure `body` is a plain object, validate types, and optionally enforce max payload size.

- **`order:accept` / `order:decline` / `order:update`** (311–312, 331–332, 348–350): `orderId` is only trimmed and checked for non-empty. No format validation (e.g. UUID).  
  **Fix:** Validate `orderId` format (e.g. UUID) and length to avoid abuse and bad keys.

- **`order:update`** (350): `status` is trimmed and passed as `status as any` into `updateOrderStatus`. The service later validates transitions, but the gateway does not restrict to allowed enum values.  
  **Fix:** Validate `status` against the allowed `OrderStatus` enum before calling the service.

---

### 2.2 **No try/catch in socket handlers — unhandled rejections and poor client feedback**

**File:** `events.gateway.ts`

- **`order:decline`** (324–337): `await this.orders.declineOrder(orderId, user.phone.trim())` is not in try/catch. If `getOrder` throws (e.g. order not found) or Redis fails, the promise rejects. The WebSocket layer may not send a structured error back to the client.  
  **Fix:** Wrap in try/catch and return something like `{ ok: false, error: '...' }` with an appropriate message/code.

- **`order:update`** (339–356): `await this.orders.updateOrderStatus(...)` and `await this.orders.findNearbySearchingOrderForDriver(...)` are not in try/catch. Any thrown error (e.g. ConflictException, NotFoundException) can lead to an unhandled rejection and no clear response to the driver.  
  **Fix:** Wrap in try/catch and map exceptions to a consistent socket response (e.g. `{ ok: false, error: 'ORDER_NOT_FOUND' }`).

---

### 2.3 **Async callback in timer — unhandled rejection can crash process**

**File:** `events.gateway.ts`  
**Lines:** 278–282

**Issue:** `runSearchRound` is invoked from `setTimeout` and is async. If an error is thrown after the first `await` (e.g. in `getNearbyDrivers`, `getOrder`, or later), it becomes an unhandled promise rejection. In Node, that can terminate the process if no global handler is configured.

**Fix:** Wrap the body of `runSearchRound` in try/catch and log errors; optionally notify or retry instead of letting the promise reject unhandled.

---

### 2.4 **Event names**

**Finding:** Event names are consistent and descriptive (`driver:location`, `driver:status`, `order:accept`, `order:decline`, `order:update`, `order:new`, `order:status`, `order:taken`, `order:canceled`, `order:delay`, `driver:blocked`, `driver:unblocked`, `commission:cleared`). No wrong or misleading names identified.

---

## 3. Race conditions in order dispatch

### 3.1 **Driver accept — properly protected**

**File:** `orders.service.ts` (referenced from `events.gateway.ts`)

**Finding:** `acceptOrder` uses a Redis `SET key value EX 30 NX` lock (`orderLockKey(orderId)`). Only one driver can acquire the lock; others get “Order already taken”. Status is re-read after acquiring the lock. So two drivers cannot both accept the same order. No change required for this path.

---

### 3.2 **Admin assign vs driver accept — race**

**File:** `admin.controller.ts` (385–396), `orders.service.ts` (727–747)

**Issue:** `assignDriver` does **not** use the same order lock as `acceptOrder`. If a driver is in the middle of `acceptOrder` (holding the lock) and an admin calls `POST /admin/orders/:id/assign` with another driver, `assignDriver` will load the order and overwrite it with the new driver. Outcome depends on timing: either the driver’s accept is overwritten by admin, or admin’s assign is overwritten by the driver.

**Fix:** Have `assignDriver` acquire the same order lock (e.g. `orderLockKey(orderId)`) before reading/updating the order, and release it in a `finally` block, similar to `acceptOrder` and `adminCancel`.

---

## 4. Rate limiting

### 4.1 **OTP verify — per-phone attempt limit only**

**File:** `otp.service.ts` (67–84)

**Finding:** Verify is limited to `OTP_MAX_ATTEMPTS` (default 5) per phone. So brute force on a **single** number is limited. There is no global rate limit, so an attacker could try many OTPs across many phone numbers (e.g. 5 attempts per number for many numbers).

**Recommendation:** Add a global rate limit (e.g. by IP or by API key) on `POST /auth/otp/verify` (and optionally on request) to cap total attempts across all phones.

---

### 4.2 **OTP request — cooldown per phone only**

**File:** `otp.service.ts` (41–65)

**Finding:** Request has a per-phone cooldown (`OTP_COOLDOWN_SEC`). There is no global or per-IP limit, so an attacker can trigger SMS to many different numbers in parallel and cause SMS flood / cost.

**Recommendation:** Add global/per-IP rate limiting on `POST /auth/otp/request`.

---

### 4.3 **Admin login — no rate limiting**

**File:** `auth.controller.ts` (46–61)

**Issue:** `POST /auth/admin/login` has no rate limiting. An attacker can brute force `ADMIN_LOGIN` / `ADMIN_PASSWORD` with no backoff or lockout.

**Fix:** Add rate limiting (e.g. by IP) and optionally account lockout or CAPTCHA after several failed attempts.

---

### 4.4 **No application-level rate limiting elsewhere**

**Finding:** No use of `@Throttle`, `rate-limit`, or similar in the codebase. Only OTP verify has per-phone attempt limits. Other endpoints (admin, client, drivers) are not rate limited and are vulnerable to abuse and DoS.

**Recommendation:** Add a global rate limit (e.g. NestJS Throttler) and stricter limits for auth and admin endpoints.

---

## 5. Input validation — missing or weak

### 5.1 **Auth OTP request — missing/null phone can crash**

**File:** `auth.controller.ts`  
**Line:** 16

**Issue:** `request(@Body() body: { phone: string })` calls `this.otp.requestOtp(body.phone)` without checking `body` or `body.phone`. If `body` is `{}` or `body.phone` is `undefined`, `normalizePhone` in `otp.service.ts` will call `undefined.replace(...)` and throw. The process may not “crash” but the request will 500.

**Fix:** Validate before calling OTP: ensure `body?.phone` is a non-empty string (and optionally format), then call `requestOtp`.

---

### 5.2 **Auth OTP verify — weak validation**

**File:** `auth.controller.ts`  
**Line:** 29

**Issue:** `verify(@Body() body: { phone: string; code: string; ... })` does not validate that `body.phone` and `body.code` are present and strings before calling `verifyOtp`. Missing or wrong types can lead to errors inside `verifyOtp` or confusing responses.

**Fix:** Validate `body.phone` and `body.code` (type and length) and return 400 with a clear message if invalid.

---

### 5.3 **Client controller — JSON.parse without try/catch**

**File:** `clients.controller.ts`  
**Lines:** 28–29, 56–58, 125–128

**Issue:** `getProfile`: `const profile = raw ? JSON.parse(raw) : {}`. If Redis returns corrupted or non-JSON data, `JSON.parse` throws and the request returns 500. Same pattern in `saveProfile` (`existingRaw`) and `activatePromo` (`profileRaw`). Malformed or attacker-controlled Redis values can crash the handler.

**Fix:** Wrap `JSON.parse` in try/catch and on failure return a safe default or 400/500 with a controlled message; optionally validate/sanitize stored profile shape.

---

### 5.4 **Admin controller — JSON.parse and pipeline results**

**File:** `admin.controller.ts`  
**Lines:** 86–90 (listDrivers), 144–145 (approveDriver), 156–159 (rejectDriver), 213–215 (listClients), 328–329 (listTariffs)

**Issue:**  
- `listDrivers`: `JSON.parse(raw)` on profile strings. Corrupted Redis data causes throw and 500.  
- `approveDriver` / `rejectDriver`: `JSON.parse(raw)` on driver profile; invalid JSON throws.  
- `listClients`: same for client profiles.  
- `listTariffs`: `JSON.parse(raw)` for tariffs list; invalid data throws.

**Fix:** Use try/catch around all `JSON.parse` from Redis; on failure log, use a safe default or return a structured error instead of letting the exception bubble.

---

### 5.5 **Admin controller — requireAdmin throws generic Error**

**File:** `admin.controller.ts`  
**Lines:** 37–38

**Issue:** `if (!secret) throw new Error('JWT_SECRET not set');` throws a generic `Error`. Nest will treat it as 500. It also leaks an internal configuration detail (“JWT_SECRET not set”) in the response.

**Fix:** Throw a dedicated exception (e.g. `InternalServerErrorException` or a custom one) with a generic message to the client and log the real reason server-side.

---

### 5.6 **Admin saveTariffs — arbitrary JSON stored**

**File:** `admin.controller.ts`  
**Lines:** 328–332

**Issue:** `saveTariffs(@Body() body: { tariffs?: any[] })` accepts any array and stores `JSON.stringify(tariffs)` in Redis. No schema or size check. Huge or deeply nested payloads can impact memory and Redis; malformed data can break consumers that parse tariffs.

**Fix:** Validate `body.tariffs` (array length, element shape, size) and reject invalid payloads with 400.

---

### 5.7 **Clients controller — referral/bonus logic and type safety**

**File:** `clients.controller.ts`  
**Lines:** 56–69, 125–128

**Issue:** `existing` is inferred from `JSON.parse(existingRaw)`; if the stored object has unexpected types (e.g. `usedReferralCode` as number), the comparison and assignment might behave unexpectedly. Same for `profile` in activatePromo. No strict validation of profile shape.

**Fix:** Validate or normalize profile shape after parse (e.g. ensure string fields, boolean for flags) and use try/catch around parse.

---

## 6. Admin panel security

### 6.1 **Admin login — no rate limiting**

**File:** `auth.controller.ts`  
**Lines:** 46–61

**Issue:** Already covered in §4.3. Brute force on admin credentials is possible.

---

### 6.2 **Admin credentials from env**

**Finding:** Admin login and password are read from `ADMIN_LOGIN` and `ADMIN_PASSWORD`. If these are missing, the endpoint throws “Admin login not configured”. No check for weak or default passwords in code.

**Recommendation:** Enforce strong defaults (e.g. fail startup if in production and password is default/empty), and use rate limiting + optional 2FA for admin.

---

### 6.3 **Admin uses same JWT secret**

**Finding:** Admin JWT is signed with the same `JWT_SECRET` as client and driver tokens. Compromise of the secret invalidates all roles. Consider separate secrets or separate issuer/audience for admin tokens to limit blast radius.

---

## 7. Driver status management

### 7.1 **updateLocation overwrites status to “online”**

**File:** `drivers.service.ts`  
**Lines:** 52–63

**Issue:** `updateLocation` always does `this.redis.client.hset(this.statusKey(), phone, 'online')` and refreshes `onlineKey`. So whenever a driver sends location (e.g. during a trip), they are forced back to `online` in the hash and remain in the “online” set. A driver who is `busy` on an active order can appear as available for new orders if they send location updates.

**Fix:** Only set status to `online` (and refresh `onlineKey`) when the current status is not `busy`, or do not change status in `updateLocation` and only update geo + location cache.

---

### 7.2 **setStatus('busy') does not touch onlineKey**

**File:** `drivers.service.ts`  
**Lines:** 41–50

**Issue:** For `status === 'online'` the code sets `onlineKey` with TTL 120s; for `'offline'` it deletes `onlineKey`. For `'busy'` it does neither. So a driver who was `online` and then set to `busy` keeps their existing `onlineKey` until it expires (120s). During that time they still appear in `getNearbyDrivers` / `listOnlineDrivers` and can receive new orders.

**Fix:** When setting status to `busy`, explicitly delete `onlineKey` (or stop including them in “available” lists) so they are not offered new orders while busy.

---

### 7.3 **Status and onlineKey can diverge**

**Finding:** Status is stored in a hash (`drivers:status`), while “online presence” is in `driver:online:${phone}` with TTL. If the app sends `driver:status` rarely but location often, or vice versa, status and presence can get out of sync (e.g. hash says `offline` but key still exists, or the opposite). Cleanup and `listDrivers` use both; inconsistent state can confuse admin and dispatch.

**Recommendation:** Keep a single source of truth (e.g. treat “online” as “has valid onlineKey” and derive from that), or always update both status and onlineKey together in a consistent way.

---

## 8. Endpoints / code paths that can crash or destabilize the process

### 8.1 **Unhandled promise rejection in setTimeout (runSearchRound)**

**File:** `events.gateway.ts`  
**Lines:** 278–282, 211–286

**Issue:** Already covered in §2.3. Async errors in `runSearchRound` can cause unhandled promise rejection and, depending on Node/config, process exit.

**Fix:** Wrap `runSearchRound` body in try/catch; log and optionally retry or notify.

---

### 8.2 **Socket handlers without try/catch**

**File:** `events.gateway.ts`  
**Handlers:** `order:decline`, `order:update`

**Issue:** Already covered in §2.2. Thrown exceptions from `orders.declineOrder` or `orders.updateOrderStatus` / `findNearbySearchingOrderForDriver` can lead to unhandled rejections in the WebSocket layer and no clear response to the client.

**Fix:** Add try/catch in both handlers and return structured error payloads.

---

### 8.3 **JSON.parse and missing validation**

**Issue:** Already covered in §5.3 and §5.4. Uncaught `JSON.parse` exceptions in HTTP handlers result in 500; in non-request contexts (if any) they could contribute to unhandled rejections. Corrupted or malicious Redis data increases risk.

**Fix:** Centralize safe parsing (e.g. helper with try/catch and defaults) and use it everywhere Redis JSON is read.

---

### 8.4 **Auth request with missing body.phone**

**File:** `auth.controller.ts`  
**Line:** 16

**Issue:** Already covered in §5.1. `body.phone` undefined leads to exception in `normalizePhone` and 500 response. Not a full process crash but a predictable server error.

**Fix:** Validate `body` and `body.phone` before calling `requestOtp`.

---

## Summary table

| # | Severity   | File                 | Line(s)    | Issue |
|---|------------|----------------------|------------|--------|
| 1.1 | Critical   | clients.controller.ts | 24–133     | Client endpoints have no auth; any clientId accepted |
| 1.2 | High      | events.gateway.ts    | 94–119, 134–136 | WS client can connect with arbitrary clientId |
| 2.1 | Medium    | events.gateway.ts    | 353–358, 311–312, 331–332, 348–350 | Socket payload validation missing/weak |
| 2.2 | Medium    | events.gateway.ts    | 324–337, 339–356 | order:decline and order:update lack try/catch |
| 2.3 | High      | events.gateway.ts    | 278–282    | runSearchRound async errors can cause unhandled rejection |
| 3.2 | Medium    | admin.controller.ts, orders.service.ts | 385–396, 727–747 | assignDriver does not use order lock; races with acceptOrder |
| 4.1–4.4 | Medium/High | auth.controller.ts, otp.service.ts | Various | No global rate limit on OTP; no rate limit on admin login or other endpoints |
| 5.1 | Medium    | auth.controller.ts   | 16         | request OTP with missing phone can throw |
| 5.2 | Low       | auth.controller.ts   | 29         | verify OTP body not validated |
| 5.3 | Medium    | clients.controller.ts | 28–29, 56–58, 125–128 | JSON.parse without try/catch |
| 5.4 | Medium    | admin.controller.ts  | 86–90, 144–159, 213–215, 328–329 | JSON.parse without try/catch; pipeline result handling |
| 5.5 | Low       | admin.controller.ts  | 37–38      | requireAdmin throws generic Error on missing JWT_SECRET |
| 5.6 | Low       | admin.controller.ts  | 328–332    | saveTariffs accepts arbitrary array; no validation |
| 5.7 | Low       | clients.controller.ts | 56–69, 125–128 | Profile/referral types not validated after parse |
| 6.1–6.3 | Medium   | auth.controller.ts   | 46–61      | Admin login no rate limit; same JWT secret; env credentials |
| 7.1 | High     | drivers.service.ts   | 52–63      | updateLocation forces status to online (breaks busy) |
| 7.2 | High     | drivers.service.ts   | 41–50      | setStatus('busy') does not clear onlineKey |
| 7.3 | Medium   | drivers.service.ts   | 41–63, 94–110 | Status and onlineKey can get out of sync |
| 8.1–8.4 | High/Medium | events.gateway.ts, auth.controller.ts, clients.controller.ts, admin.controller.ts | See above | Unhandled rejections and parse/validation errors |

---

**Recommended order of fixes**

1. **Critical:** Add authentication and authorization for all client endpoints; stop trusting `clientId` from the request only.  
2. **High:** Harden WebSocket client identity (no auth by arbitrary clientId).  
3. **High:** Fix driver status: do not set `online` in `updateLocation` when driver is busy; clear `onlineKey` when setting `busy`.  
4. **High:** Wrap `runSearchRound` and socket handlers (`order:decline`, `order:update`) in try/catch; ensure no unhandled rejections.  
5. **Medium:** Add rate limiting (global and for auth/admin).  
6. **Medium:** Use order lock in `assignDriver`; add input validation and safe JSON parsing everywhere listed above.
