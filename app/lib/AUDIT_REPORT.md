# Code audit: Flutter taxi client — main.dart

Audit focused on crashes in production, wrong data shown to users, and security. All line numbers refer to `app/lib/main.dart`.

---

## 1. Large order prices (display)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **1006–1008** | `_OrderCompletedSheet`: price shown as `'Итог: $priceRub ₽'` with no formatting or width constraint. Large values (e.g. 50000+) can overflow or wrap badly. | Use number formatting (e.g. `NumberFormat.decimalPattern('ru')`) and wrap in `FittedBox` or give the `Text` a max width / `Flexible`. |
| **2798–2805** | `_TariffCard`: price shown as `'${_applyDiscount(quote.priceFrom, discountPercent)} ₽'` in a `Column` with no `Expanded`/`FittedBox`. Large prices can overflow. | Wrap price `Text` in `FittedBox(fit: BoxFit.scaleDown)` or constrain width so long numbers don’t overflow. |
| **2810** | Same card shows `'${quote.priceFrom} ₽  ·  -$discountPercent%'` — same overflow risk for large `priceFrom`. | Same as above. |
| **3496, 5777, 8383** | History list shows `'$price ₽'` where `price` is from `item['price']?.toString()`. Long or malformed values can overflow. | Format number and/or wrap in `FittedBox` or bounded `Text`. |
| **6824–6826** | Ride price built as `'от $price₽'` — same overflow risk. | Use formatted number and/or `FittedBox`. |

---

## 2. Phone number handling

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **488** | Support number hardcoded as `'+89060424241'`. Wrong Russian format (should be +7, not +8). | Use `+79060424241` (or correct number) and consider a constant or config. |
| **1040** | Hardcoded `'8 (495) 115-95-95'` in `_OrderCompletedSheet`. Inconsistent with +7 and not reusable. | Use +7 format and centralize support number (constant/config). |
| **154–159** | `_formatPhoneForDisplay`: only formats when `digits.length == 11 && digits.startsWith('7')`. Numbers like `89061234567` are returned as-is, so user may see raw digits. | Normalize 11-digit numbers starting with `8` to `7` before formatting (e.g. `if (digits.startsWith('8')) digits = '7${digits.substring(1)}';`) so they get +7 display. |
| **6136–6142** | `_callDriver`: normalizes 8→7 and 10→7 correctly; `normalized` can still be without `+`. | Already uses `'+$digits'` when starting with 7. Ensure `tel:` URL is valid (e.g. `+79061234567`). |

---

## 3. API calls

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **18** | `_apiBaseUrl = 'http://194.67.84.155'` — plain HTTP and IP in code. | Use HTTPS and configurable base URL (e.g. env/build config). |
| **200–204, 221–225** | `requestOtp` and `verifyOtp`: no timeout. Slow or hanging server can block indefinitely. | Add `.timeout(Duration(seconds: 15))` (or similar) and handle `TimeoutException`. |
| **207, 228** | `jsonDecode(res.body)` when status is 2xx. If server returns non-JSON (e.g. HTML), this throws and is caught as generic failure. | Wrap in try/catch; on `FormatException` show a “server error” message instead of “wrong code”/“send failed”. |
| **3834–3849** | `_authGet` and `_authPost`: no timeout. Same hang risk. | Add timeout and handle it (and 401 already handled). |
| **4006, 4024, 4055, 4755, 5951, 6006, 6037, 6122, etc.** | Many `http.get`/`http.post` calls without timeout (except promo at 8101). | Add reasonable timeouts (e.g. 10–30 s) and handle `TimeoutException` so UI doesn’t hang. |
| **4018–4028** | `_loadActiveOrder`: reads `map['driverLat']` and `map['driverLng']` from top-level `map`. If API puts them under `order`, values are null and driver position never updates. | Confirm API contract; if coordinates are under `order`, use `order['driverLat']` / `order['driverLng']`. |
| **6018–6019** | Polling uses `map['driverLat']` and `map['driverLng']` for GET `/api/orders/$orderId`. Same possible mismatch. | Same as above: use the same level as the API (root vs `order`). |
| **5972–5973** | Create order: `jsonDecode(res.body)` can throw on malformed 2xx response. | Wrap in try/catch; in catch, set `_creatingOrder = false`, ensure `mounted` and show “Не удалось создать заказ” (or more specific message). |

---

## 4. State management (setState after dispose, race conditions)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **4389** | In `_handleOrderStatus` for `status == 'canceled'`, after `setState` and clearing state, `ScaffoldMessenger.of(context).showSnackBar` is used without checking `mounted`. If widget was disposed (e.g. user left screen), using `context` can crash. | Add `if (!mounted) return;` before `ScaffoldMessenger.of(context).showSnackBar(...)`. |
| **4426–4445** | `_handleDriverLocation` is `async`. After `if (!mounted) return` it does `await controller.moveCamera(...)`. After the await the widget may be disposed. | Add `if (!mounted) return;` immediately after the `await moveCamera` before any further use of state/context. |
| **5999–6068** | `_statusPollTimer` callback is `async` and uses `await _ensureClientId()`, `await http.get`, etc. After each await the widget may be disposed; later code uses `setState` and `_handleOrderStatus`. | Add `if (!mounted) return;` after every `await` in this callback before touching state or calling `setState`/`_handleOrderStatus`. |
| **4328** | `_handleOrderStatus` checks `if (!mounted) return` only at the start. Long sync path and multiple `setState` calls; in theory another callback could dispose the widget. | Optionally add `if (!mounted) return;` immediately before each `setState` in this handler for extra safety. |

---

## 5. SharedPreferences (data loss / corruption)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3463, 5744, 8350** | Order history: `jsonDecode(raw) as List<dynamic>`. If stored string is corrupted or not JSON, `jsonDecode` throws and the `FutureBuilder` builder crashes. | Wrap in try/catch; on error use `items = <dynamic>[]` and optionally show “Ошибка загрузки истории” or retry. |
| **6084** | `_saveOrderHistory`: `final list = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>);`. Corrupted `raw` causes throw; history is not saved and exception propagates. | Wrap in try/catch; on error start from empty list: `list = <dynamic>[]`, then insert new entry and save. |
| **6093** | `list.take(50).toList()` — if `list` is mutated (e.g. by another isolate or bug), ensure we don’t persist invalid structure. | Already limited to 50; ensure `list` is a fresh list from safe decode above. |
| **6084 + 6093** | Read-modify-write of history: no atomicity. App kill during write can leave truncated or corrupted JSON. | Consider reading again after write and validating, or use a single serialized update; document “best effort” and handle decode errors. |

---

## 6. UI (overflow, null checks, hardcoded strings)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3463, 5744, 8350** | No handling of `snapshot.hasError` or `snapshot.connectionState`. Loading is treated as empty list; error state is not. | If `snapshot.hasError` show error widget; if loading show progress; only decode when `snapshot.hasData`. |
| **3475, 5760, 8362** | `final item = items[index] as Map<String, dynamic>`. If a history entry is not a Map (corrupted data), cast throws. | Use safe cast or try/catch; skip or show “?” for invalid entries. |
| **591–592** | `if (note != null && note!.trim().isNotEmpty)` — redundant `note!` after null check. | Use `note!.trim()` or just `note.trim()` after the null check. |
| **1040, 488** | Hardcoded support numbers — not localizable and wrong format (see phone section). | Centralize and use +7 format. |
| **Many** | Russian strings in UI ('Здравствуйте!', 'Получить код', 'Итог: ...', etc.) are hardcoded. | Move to localization (e.g. `AppLocalizations`) for future i18n. |

---

## 7. Payment / promo code logic

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **8105–8107** | `final discount = (data['discount'] ?? 0) as int;` — if server sends double or string (e.g. `10.5` or `"15"`), cast throws. | Parse safely: e.g. `int.tryParse(data['discount']?.toString() ?? '') ?? 0` and clamp to 0..100. |
| **7775–7780** | `_savePromo(code, discount)`: discount is stored as-is. If API returns &gt;100 or negative, UI can show wrong “-150%” and `_applyDiscount` can behave oddly (e.g. large percent). | Clamp before save: `discount = discount.clamp(0, 100)`. |
| **134–136** | `_applyDiscount`: for `percent > 100`, result is clamped to ≥ 0, but displaying “-150%” is misleading. | Clamp `percent` to 0..100 at use or in `_applyDiscount`. |
| **6085–6090** | Order payload uses `_applyDiscount(quote.priceFrom, _promoDiscountPercent)` and sends `'discount': _promoDiscountPercent`. Server should validate discount; client trusts stored value. | Ensure server validates discount and price; client-side clamp is still recommended. |

---

## 8. Socket.IO

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **3956–3953** | `setReconnectionAttempts(double.maxFinite.toInt())` — infinite reconnects can keep trying on bad network and burn battery. | Use a finite max (e.g. 10–20) and then show “Нет связи” or similar. |
| **3999** | `s.onError((_) {});` — errors are ignored; no logging or user feedback. | Log in debug; consider showing SnackBar after repeated errors. |
| **3977** | `_handleOrderStatus` is invoked from socket callback; no explicit `mounted` check before first `setState` in that path (only at 4328 at start). | Already noted in state management; add `if (!mounted) return;` before each `setState` in socket-driven handlers. |
| **3963** | `unawaited(_loadActiveOrder());` on connect — if `_loadActiveOrder` throws, it’s an unhandled future. | Keep in try/catch inside `_loadActiveOrder` (already there); ensure no throw in socket callback. |

---

## 9. Map / geocoding (Yandex)

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **1724–1726, 1905–1906, 1883–1885** | `await futureResult` and `await session.close()` — if Yandex SDK or network fails, exceptions are caught in caller (`catch (e, st)` at 1774, 1831, 1898). Fallback used. | Ensure all branches set `_suggestLoading = false` and don’t leave loading state on error (already set in catch at 1783–1785). |
| **5288–5310** | `_reverseGeocode`: `session.close()` in try; if `futureResult` throws, session may not be closed. | Use `try { result = await futureResult; } finally { await session.close(); }` so session is always closed. |
| **5483–5509** | `_formatSuggestionAddress`: same pattern — `await session.close()` only on success path. | Same: close session in `finally`. |
| **4468–4476** | `_updateLiveRoute`: session closed in `finally`; good. `result.error` and empty `routes` are handled. | No change needed. |
| **4583–4588** | `_loadDriverProfile`: `http.get` with no timeout; driver profile API failure is caught but user gets no feedback. | Add timeout; optionally show “Не удалось загрузить профиль” on repeated failure. |

---

## 10. Security

| Line(s) | Issue | Fix |
|--------|--------|-----|
| **18** | API base URL (and IP) hardcoded. Easy to change for different envs but also visible in app. | Prefer build-time config (e.g. flavor/env) and HTTPS. |
| **48–65** | Token stored in SharedPreferences. On rooted/jailbroken devices other apps could read it. | Acceptable for many apps; for higher security consider encrypted storage (e.g. flutter_secure_storage). |
| **3835, 3844** | Token sent in `Authorization: Bearer`. Ensure no logging of headers. | Avoid logging full headers in production. |
| **3949** | Socket auth: `setAuth({'token': widget.token, 'clientId': clientId})` — token in memory only here; ensure not logged. | Same as above; no logging of auth payload. |

---

## Summary (priority)

**High (crash or wrong data)**  
- Order history and `_saveOrderHistory`: wrap `jsonDecode` in try/catch and handle corrupted JSON (lines 3463, 5744, 8350, 6084).  
- History list: handle `snapshot.hasError` and safe-cast `items[index]` (3475, 5760, 8362).  
- Promo: safe parse and clamp `discount` (8105–8107, 7775–7780).  
- Auth API: handle non-JSON 2xx responses (207, 228).  
- setState/context: add `mounted` checks after async in socket and polling (4389, 4426–4445, 5999–6068).

**Medium (reliability / UX)**  
- Add timeouts to all HTTP calls; handle `TimeoutException`.  
- Use HTTPS and configurable API base URL.  
- Phone: fix +8 → +7 and centralize support numbers (488, 1040, 154–159).  
- Large price display: format numbers and prevent overflow (1006–1008, 2798–2810, 3496, etc.).  
- Yandex: close session in `finally` in `_reverseGeocode` and `_formatSuggestionAddress`.

**Lower**  
- Socket: finite reconnection attempts and basic error handling.  
- Localization of hardcoded strings.  
- Optional token in secure storage for higher security.
