# Команды сборки Android (APK)

Flutter лежит в: `C:\Users\user\CascadeProjects\2048\flutter\bin\flutter.bat`

## Клиентское приложение
```
cd c:\Users\user\CascadeProjects\2048\app
C:\Users\user\CascadeProjects\2048\flutter\bin\flutter.bat build apk --release
```

## Водительское приложение
```
cd c:\Users\user\CascadeProjects\2048\prosto_taxi_driver
C:\Users\user\CascadeProjects\2048\flutter\bin\flutter.bat build apk --release
```

Готовые APK (полные пути от корня 2048):
- **Клиент:** `app\build\app\outputs\flutter-apk\app-release.apk`
- **Водитель:** `prosto_taxi_driver\build\app\outputs\flutter-apk\app-release.apk`  
  (папка: `C:\Users\user\CascadeProjects\2048\prosto_taxi_driver\build\app\outputs\flutter-apk`)

## App Bundle (AAB) для Google Play

На Windows с Flutter 3.32+ и NDK 27 команда `flutter build appbundle` может выдать ошибку про strip debug symbols — при этом **Gradle часто уже создаёт готовый .aab**.

**1) Проверь, есть ли файл после «неудачной» сборки:**
```
prosto_taxi_driver\build\app\outputs\bundle\release\app-release.aab
```
Если он есть — его можно загружать в Google Play (проверка Flutter не обязательна для публикации).

**2) Если файла нет — собери AAB только через Gradle (без проверки Flutter):**

Если выдаёт «JAVA_HOME is not set», в той же сессии cmd выполни (путь к Java из Android Studio):
```
set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
```
Если Android Studio в другом месте — укажи папку `jbr` (без \bin), например:
```
set "JAVA_HOME=%LOCALAPPDATA%\Programs\Android Studio\jbr"
```

Затем сборка:
```
cd c:\Users\user\CascadeProjects\2048\prosto_taxi_driver
C:\Users\user\CascadeProjects\2048\flutter\bin\flutter.bat pub get
cd android
gradlew.bat bundleRelease
```
Готовый AAB: `prosto_taxi_driver\build\app\outputs\bundle\release\app-release.aab`

**3) Обычная сборка (если когда-нибудь заработает без ошибки):**
```
cd c:\Users\user\CascadeProjects\2048\prosto_taxi_driver
C:\Users\user\CascadeProjects\2048\flutter\bin\flutter.bat build appbundle --release
```

## Подпись релиза (ключ для Google Play)

Подпись задаётся в **`android/key.properties`** (в папке `app/android/` для клиента, `prosto_taxi_driver/android/` для водителя). Формат:
```
storeFile=путь/к/файлу.jks
storePassword=пароль
keyAlias=алиас
keyPassword=пароль_ключа
```
Путь `storeFile` — относительно папки `android/` или абсолютный.

Если Play пишет «подписан неправильным ключом», нужен **тот же** keystore, что использовался при первой загрузке приложения. Отпечаток ожидаемого ключа (SHA1) указан в ошибке Play Console.

Проверить SHA1 своего keystore:
```
keytool -list -v -keystore путь/к/файлу.jks
```
В выводе найдите **SHA1** — он должен совпадать с тем, что просит Play. После смены ключа в `key.properties` пересоберите AAB.

### Потерян ключ загрузки (Play пишет «неправильный ключ»)

Если нужного .jks нет, можно **запросить сброс ключа загрузки** в Google Play:

1. **Экспорт сертификата в PEM** (уже сделан для клиента):
   - Файл: `app\android\upload_certificate.pem`
   - Повторно:  
     `keytool -exportcert -alias upload_client -keystore app\android\release-keystore.jks -storepass ПАРОЛЬ -rfc -file app\android\upload_certificate.pem`

2. **В Play Console:** выберите приложение → **Выпуск** → **Настройка** → **Подписывание приложения** (или **Setup** → **App signing**).

3. Найдите блок **«Потерян или скомпрометирован ключ загрузки?»** / **«Lost or compromised upload key?»** и нажмите **«Запросить сброс ключа»** / **«Request upload key reset»**.

4. Загрузите файл **`upload_certificate.pem`** (новый ключ загрузки). Инициатором должен быть **владелец аккаунта** разработчика.

5. После одобрения Google (письмо в Inbox и на email) подписывайте AAB текущим ключом (`app\android\release-keystore.jks`, alias `upload_client`) и загружайте в Play как обычно.
