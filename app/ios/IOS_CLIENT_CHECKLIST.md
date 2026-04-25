# Чеклист iOS-клиента «Просто Такси»

Приложение-клиент (`app/`) настроено под iOS так же, как под Android: темы, уведомления, разрешения и функции из одного кода.

---

## 1. Podfile (`app/ios/Podfile`)

| Разрешение | Переменная | Назначение |
|------------|------------|------------|
| Геолокация | `PERMISSION_LOCATION=1` | Маршруты, карта, адреса |
| Фото | `PERMISSION_PHOTOS=1` | Выбор фото профиля (галерея) |
| Уведомления | `PERMISSION_NOTIFICATIONS=1` | Переключатель «Уведомления» в настройках |

Платформа: `platform :ios, '12.0'`.

После изменений в Podfile: `cd app/ios && pod install`.

---

## 2. Info.plist (`app/ios/Runner/Info.plist`)

| Ключ | Назначение |
|------|------------|
| `CFBundleDisplayName` | «Prosto Taxi» — название под иконкой |
| `NSLocationWhenInUseUsageDescription` | Запрос геолокации при построении маршрута |
| `NSPhotoLibraryUsageDescription` | Доступ к галерее для фото профиля |
| `LSApplicationQueriesSchemes` | `tel`, `https`, `http`, `mailto` — звонки, ссылки, почта |
| `YANDEX_MAPS_KEY` | Ключ карт из `ios/Flutter/Secrets.xcconfig` |

---

## 3. Функции клиента (общий код, без отдельной iOS-логики)

| Функция | Где реализовано | iOS |
|---------|------------------|-----|
| Тема (светлая/тёмная) | `main.dart`: `_themeModeKey`, `_loadTheme`, `_setThemeMode` | Работает |
| Сохранение темы | SharedPreferences | Работает |
| Уведомления (вкл/выкл) | Настройки: `_notificationsEnabledKey`, `Permission.notification.request()` | Работает при `PERMISSION_NOTIFICATIONS=1` |
| Профиль, адреса, промокод | SharedPreferences + API | Работает |
| Карта и маршруты | Yandex MapKit, ключ из Secrets.xcconfig | Работает |
| Геолокация | Geolocator + разрешение в Podfile/Info | Работает |
| Фото профиля | Image Picker + разрешение фото | Работает |

---

## 4. Сборка IPA

1. Заполнить ключ в `app/ios/Flutter/Secrets.xcconfig`: `YANDEX_MAPS_KEY=ваш_ключ`.
2. Открыть `app/ios/Runner.xcworkspace` в Xcode.
3. Выбрать схему **Runner**, целевое устройство (Generic iOS Device или конкретный девайс).
4. **Product → Archive** → **Distribute App** → выбрать способ (Ad Hoc / App Store) и экспортировать IPA.

---

## 5. Отличие от приложения водителя

Клиент не использует:

- фоновую геолокацию;
- камеру;
- локальные уведомления заказов (как у водителя).

Используются только: темы, переключатель уведомлений с запросом разрешения, карта, профиль, заказы — всё это в одном коде и настроено для iOS по этому чеклисту.
