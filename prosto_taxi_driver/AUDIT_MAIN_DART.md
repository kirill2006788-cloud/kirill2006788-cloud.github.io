# Code Audit: Flutter Taxi Driver App — main.dart

**File:** `prosto_taxi_driver/lib/main.dart`  
**Focus:** Bugs that can crash in production or show wrong data to users.

---

## 1. Large order prices (50000+ rubles)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **5906, 5919** | `_PriceBlock` shows `'$price ₽'` with no thousands separator. Large amounts (e.g. 150000) display as "150000 ₽" and are harder to read. | Use the same formatting as `_ProfileTileEarnings._formatRub()` (space-separated thousands) for consistency and readability. |
| **5375, 1564** | Trip list and card use raw `'$price ₽'` / `'${tripPriceRub!} ₽'` with no formatting. | Apply `_formatRub`-style formatting for prices in these places. |
| **5048** | Notification body: `'... ${order.priceRub} ₽'` — no formatting. | Optional: format for notifications. |

**Verdict:** No crash or wrong number; display is just unformatted for large amounts. Recommend reusing `_formatRub` (or a shared formatter) for all price displays.

---

## 2. Earnings display (negative, NaN, overflow)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **623–624** | `_parseInt(dynamic value, int fallback)` uses `int.tryParse(value?.toString() ?? '')`. If the API sends a **double** (e.g. `1234.56`), `int.tryParse("1234.56")` is **null** in Dart, so earnings fall back to previous/stale value. | Parse numeric earnings robustly, e.g. `(value is num) ? (value as num).toInt() : (int.tryParse(value?.toString() ?? '') ?? fallback)`. |
| **484–494** | `_formatRub(int value)` uses `value.abs()` and builds a string. For valid `int` there is no overflow. If `earnedRub` were ever negative, it would show as `-1234` (correct). | Ensure all call sites pass `int` from safe parsing (see above). |
| **827–828, 850, 849** | Profile and bonus use `_parseInt(profile['earnedRub'], ...)` and `_parseInt(bonus?['available'], ...)`. Same double→null issue. | Use the same numeric parsing as above for all earnings/bonus fields. |

**Verdict:** Wrong data: if API returns earnings as double, UI can show 0 or old value. Fix parsing for earnings and bonus.

---

## 3. Commission blocking logic

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3628, 4039, 4165, 4173, 4192, 4201** | Accept and overlay flows correctly check `_earningsLimitReached` before accepting and when showing overlay. Server ack also handles `EARNINGS_LIMIT_REACHED`. | No bug. |
| **2351, 3776** | `_earningsLimitReached` is set from `_checkBlockStatus()` and `commission:cleared`; overlay is cleared when limit is no longer reached. | No bug. |
| **2581–2594** | Going online is blocked when `_earningsLimitReached` and re-checked via `_checkBlockStatus()` before allowing online. | No bug. |

**Verdict:** Commission blocking and thresholds are consistent. No bypass or obvious race beyond normal async ordering.

---

## 4. Pre-order system

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3364–3366, 3371–3373** | `_preorderReminderShown60` and `_preorderReminderShown30` are **not persisted**. After app restart, preorder is restored from SharedPreferences but flags are reset, so 60‑min and 30‑min reminders can fire again for the same preorder. | Persist these flags with the preorder (e.g. in same prefs key or separate keys) and restore them in `_restorePreorder()`. |
| **3350–3354** | `_startPreorderCheckTimer()` runs a 30s periodic timer and immediately calls `_checkPreorderTiming()`. If multiple code paths call `_startPreorderCheckTimer()` (e.g. restore + socket), timer is cancelled and recreated; no duplicate timer, but duplicate “immediate” checks are possible. | Document or narrow when `_startPreorderCheckTimer()` is called to avoid redundant immediate checks. |
| **3412, 3462, 3669, 4082, 4092** | `_preorderCheckTimer?.cancel()` is called in several branches before creating a new timer or clearing preorder. | No bug. |
| **4545** | `_StoredPreorderBanner` is only built when `_preorder!.scheduledAt != null`, so null `scheduledAt` never reaches the banner. | No bug. |

**Verdict:** Main issue: duplicate 60/30‑minute reminders after restart. Fix by persisting and restoring reminder flags.

---

## 5. Order status transitions

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3534–3542** | `_statusToUi` maps only `accepted`, `enroute`, `arrived`, `started`, `completed`; anything else (e.g. `declined`, `canceled`) becomes `incoming`. For `order:status` with `canceled` we return before this; for unknown status we set `incoming` and the 800ms delayed block clears `_order`. | Acceptable; driver ends in “free” state. |
| **3715–3725** | When `nextState == incoming` we schedule a delayed clear of `_order` and route state. All delayed callbacks use `if (!mounted) return` before `setState`. | No bug. |
| **3691** | We only process when `orderId == _order!.id`. If server sends status for another order, we ignore it. | Correct. |

**Verdict:** No stuck state identified; transitions and delayed clears are consistent with `mounted` checks.

---

## 6. API calls (error handling, URLs, timeouts)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **71** | `_apiBaseUrl = 'http://194.67.84.155'` — no `/api` suffix; paths are built with `$_apiBaseUrl/api/...`. | Correct. |
| **161–165, 182–185, 804–807, 915–922, 1447, 2315, 2325, 3547, 3899** | **No timeout** on `http.get` / `http.post`. Slow or hanging network can block forever. | Add `.timeout(Duration(seconds: 15))` (or similar) to all `http.get`/`http.post` calls and handle `TimeoutException`. |
| **2314–2326** | `_checkBlockStatus` uses `_authGet(uri)` and then `jsonDecode(res.body)`. Not inside try/catch in this method; caller does not wrap it. | `_checkBlockStatus` is called from `initState` (via unawaited futures) and from `_statusPollTimer`; if response is non-JSON or malformed, `jsonDecode` can throw. Wrap in try/catch and optionally log. |
| **2340** | `jsonDecode(res.body)` in `_checkBlockStatus` — will throw on malformed JSON. | Same as above: try/catch and fallback (e.g. keep previous state). |

**Verdict:** Add timeouts to all HTTP calls and ensure `_checkBlockStatus` (and any similar path) does not let `jsonDecode` throw uncaught.

---

## 7. Socket.IO (reconnection, stale data, handlers)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3614–3623** | `onReconnect` runs `_loadActiveOrder()` and `_restoreActiveOrder()`. Both can update `_order`/`_orderState`; order of completion is undefined, so **race** between server state and local prefs. | Prefer a single source of truth: e.g. on reconnect call only `_loadActiveOrder()` and, only if it returns “no active order”, then run `_restoreActiveOrder()`. Or merge results with clear precedence. |
| **3622** | `_restoreActiveOrder()` (called on reconnect) contains **jsonDecode(raw) without try/catch** — see SharedPreferences section. | Wrap in try/catch; on parse error clear prefs and do not restore. |
| **3602–3612, 3615–3613** | All socket handlers check `if (!mounted) return` before `setState`. | Good. |
| **3792–3798** | `onConnectError` checks message for auth-related keywords and calls `_handleSessionExpired()`; no `setState` there. | No bug. |

**Verdict:** Fix `_restoreActiveOrder` JSON parsing and define clear ordering between `_loadActiveOrder` and `_restoreActiveOrder` on reconnect to avoid inconsistent state.

---

## 8. Map pins and navigation (null coordinates, errors)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **2772–2770, 2774–2800** | `_refreshRoutePreview()` uses `routeFrom`/`routeTo` only when non-null; map objects are built with `if (pickupPoint != null)`, `if (dropoffPoint != null)`. No use of null points in Yandex APIs. | No bug. |
| **2854–2856** | `_fitRouteBounds(points)` is only called when `points.isNotEmpty`. | No bug. |
| **3023–3033** | `_openOrderNavigator()` returns if `order == null` or `target == null` (pickup/dropoff point). | No bug. |
| **2611–2615** | `_ensureDrivingRoute` uses `from`/`to`; caller only passes non-null `routeFrom`/`routeTo`. | No bug. |
| **2646–2654** | Yandex driving request is in try/catch; on failure a fallback polyline is used. | No bug. |

**Verdict:** Map and navigation code guards null points and handles route errors. No crash risk identified.

---

## 9. Profile / registration (losing registration status)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **2356–2359** | Registration status from `_checkBlockStatus()` is written to SharedPreferences and overwrites the previous value. If the API once returns `registrationStatus` other than `'completed'` (e.g. empty or bug), we persist that and on next launch `_restoreOnlineStatus()` (2289–2296) restores it. Driver can appear “incomplete” until next successful poll with `completed`. | Treat server as source of truth but avoid overwriting a known `completed` with a clearly wrong value (e.g. empty). Optionally only persist when value is non-empty or when it is `completed`. |
| **2289–2296** | We restore `savedRegStatus` from prefs. If it was never set (e.g. old install) we keep default. | No bug. |
| **2382–2386** | Registration-approved dialog is shown once per device via `reg_approved_shown`. | No bug. |

**Verdict:** Rare but possible: one bad API response can overwrite “completed” and make the driver look unregistered until the next good poll. Harden persistence logic.

---

## 10. Timer leaks (Timer.periodic not cancelled in dispose)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **2463–2473** | Main home state: `dispose()` cancels `_statusPollTimer`, `_preorderCheckTimer`, `_tripTimer`, disposes socket, cancels `_posSub`. | No leak. |
| **3349, 3462, 3474, 3481, 3504, 3510** | Trip/preorder timers are cancelled when state changes or before creating a new timer. | No leak. |
| **5547–5549, 5733–5735** | `_StoredPreorderBannerState` and `_PreorderBannerState` cancel `_timer` in `dispose()`. | No leak. |

**Verdict:** All `Timer.periodic` usages are cancelled in `dispose()` or before being replaced. No timer leaks found.

---

## 11. setState after dispose (async callbacks)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **247–264, 313–339** | `_AuthGateState`: async `_load`, `_onLoggedIn`, `_logout` check `if (!mounted) return` before `setState`. | Good. |
| **321–332, 352–354** | Login: `setState` after async is guarded by `if (!mounted) return`. | Good. |
| **3716–3724, 4105–4110, 4119–4125, 4138–4143, 4159–4164, 4185–4190, 4231–4238, 4336–4339, 4579** | All `Future.delayed` and async callbacks that call `setState` use `if (!mounted) return` first. | Good. |
| **2358–2359** | `SharedPreferences.getInstance().then((prefs) => prefs.setString(...))` — callback does not call `setState`. | No bug. |
| **3602–3613, 3670, 3703, 3717, 3756, 3768, 3907** | Socket and order handlers use `if (!mounted) return` before `setState`. | Good. |

**Verdict:** No setState-after-dispose found; async paths are consistently guarded with `mounted`.

---

## 12. SharedPreferences / JSON decode (try/catch)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3231** | **CRASH:** `_restoreActiveOrder()` does `final map = jsonDecode(raw) as Map<String, dynamic>;` with **no try/catch**. If `raw` is corrupted (e.g. partial write, bad app version), the app can crash. Called from `initState` (unawaited) and from **socket `onReconnect`**. | Wrap in try/catch; on error remove `_activeOrderPrefsKey` and `_activeOrderStateKey`, do not restore, optionally log. |
| **762–789** | Profile load from prefs: `jsonDecode(raw)` and `base64Decode(avatarBase64)` are inside try/catch. | Good. |
| **3331–3344** | `_restorePreorder()`: `jsonDecode(raw)` is inside try/catch; on error prefs are removed. | Good. |
| **817** | `_fetchProfileFromServer`: `jsonDecode(res.body)` is inside try/catch (799–882). | Good. |
| **853** | `base64Decode(avatarBase64)` in profile fetch is in try/catch; invalid base64 is caught. | Good. |
| **873** | `SharedPreferences.getInstance().then((p) => p.setString(_profilePrefsKey, jsonEncode(cacheMap)))` — `jsonEncode` can throw if `cacheMap` contains non-encodable values. Currently all values are primitives or list; if `avatarBytes` were ever added to cacheMap, encoding could be large but not throw. | Low risk; ensure cache map only contains JSON-serializable types. |
| **1449** | Trips: `jsonDecode(res.body)` is inside try/catch (1444–1453). | Good. |
| **2340** | `_checkBlockStatus`: `jsonDecode(res.body)` can throw; method is not wrapped in try/catch. | Wrap `_checkBlockStatus` body (or at least the decode and profile handling) in try/catch. |
| **2410** | Auth API and `_apiErrorMessage` use `jsonDecode`; auth is in request/response flow with throws; error message is in catch. | Acceptable. |
| **3549** | `_loadActiveOrder`: `jsonDecode(res.body)` is inside try/catch (3546–3585). | Good. |
| **3901** | `_fetchOrderDetails`: `jsonDecode(res.body)` is inside try/catch. | Good. |

**Verdict:** Critical: **line 3231** can crash on corrupted active-order prefs. High: **2340** can throw on malformed profile response. All other JSON reads are either in try/catch or in already-throwing flows. Fix 3231 and 2340.

---

## Summary: must fix (crash or wrong data)

1. **Line 3231** — Wrap `_restoreActiveOrder()` JSON read in try/catch; on failure clear active-order prefs and skip restore.
2. **Lines 2340, 2315–2345** — Wrap `_checkBlockStatus()` body (or decode + profile handling) in try/catch so malformed profile response does not crash.
3. **Lines 623–624 (and all _parseInt call sites for earnings)** — Parse numeric fields so that double values from API (e.g. `1234.56`) are converted to int instead of falling back to stale/zero (use `(value is num) ? (value as num).toInt() : ...`).
4. **All http.get/http.post** — Add `.timeout(Duration(seconds: 15))` (or similar) and handle `TimeoutException`.
5. **Preorder reminder flags** — Persist and restore `_preorderReminderShown60` and `_preorderReminderShown30` so reminders are not duplicated after app restart.
6. **On reconnect** — Resolve race between `_loadActiveOrder()` and `_restoreActiveOrder()` (e.g. restore only when server says no active order, or merge with clear precedence).

## Recommended (UX / robustness)

- Use `_formatRub` (or shared formatter) for all price displays (order card, trip list, notifications).
- Only persist registration status when value is non-empty or when `completed`, to avoid overwriting “completed” with a bad server value.
- Ensure profile cache map and any prefs JSON only contain JSON-serializable types.

---

*Audit completed; line numbers refer to main.dart at time of review.*
