# Android Release Checklist

Use this list to finish Android delivery for both Flutter apps:

- `app` -> package `ru.prostotaxi.client`
- `prosto_taxi_driver` -> package `ru.prostotaxi.driver`

## 1. Google Play Console

- Create both app entries in Google Play Console.
- Link the package names exactly:
  - `ru.prostotaxi.client`
  - `ru.prostotaxi.driver`
- Fill store listing basics:
  - app name
  - short description
  - full description
  - screenshots
  - icon
  - privacy policy URL

## 2. Upload keys

- Generate one upload keystore per app or explicitly choose one shared upload key policy.
- Keep the original `.jks` files in a safe private location.
- Record for each app:
  - keystore password
  - key alias
  - key password

Windows helper:

```powershell
.\scripts\create-android-keystore.ps1 -App client -StorePassword "..." -KeyPassword "..."
.\scripts\create-android-keystore.ps1 -App driver -StorePassword "..." -KeyPassword "..."
```

## 3. GitHub secrets

Add these repository secrets:

### Shared

- `YANDEX_MAPS_KEY`
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` for automatic upload to Play `internal`

### Client

- `ANDROID_CLIENT_KEYSTORE_BASE64`
- `ANDROID_CLIENT_KEYSTORE_PASSWORD`
- `ANDROID_CLIENT_KEY_ALIAS`
- `ANDROID_CLIENT_KEY_PASSWORD`

### Driver

- `ANDROID_DRIVER_KEYSTORE_BASE64`
- `ANDROID_DRIVER_KEYSTORE_PASSWORD`
- `ANDROID_DRIVER_KEY_ALIAS`
- `ANDROID_DRIVER_KEY_PASSWORD`

Repository variable:

- `API_BASE_URL`
  - should be production `https://...`, not plain `http://...`

## 4. Google Play API access

- In Google Play Console, open `Setup -> API access`.
- Link the Play Console project to Google Cloud if it is not linked yet.
- Create or reuse a service account in Google Cloud.
- Generate a JSON key for that service account.
- Invite the service account email into Play Console and grant release access for both apps.
- Put the JSON content into GitHub secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`.

## 5. CI result

After secrets are added, `.github/workflows/mobile-ci.yml` will:

- build Android release `APK` for both apps
- build signed Android `AAB` for both apps
- upload the signed `AAB` artifacts
- upload both bundles to Google Play `internal`

## 6. Final blocker to fix before store review

- Replace `API_BASE_URL` with the real production `HTTPS` endpoint before store submission.
