# Mobile Release Setup

This workspace contains two Flutter applications:

- `app` -> client app
- `prosto_taxi_driver` -> driver app

## Current release identifiers

### Client

- Android `applicationId`: `ru.prostotaxi.client`
- iOS `bundle id`: `ru.prostotaxi.client`
- Display name: `Просто Такси`

### Driver

- Android `applicationId`: `ru.prostotaxi.driver`
- iOS `bundle id`: `ru.prostotaxi.driver`
- Display name: `Просто Такси Водитель`

## Local secrets

### Android

Create these files from the examples before release builds:

- `app/android/secrets.properties`
- `prosto_taxi_driver/android/secrets.properties`
- `app/android/key.properties`
- `prosto_taxi_driver/android/key.properties`

Examples:

- `app/android/secrets.example.properties`
- `prosto_taxi_driver/android/secrets.example.properties`
- `app/android/key.properties.example`
- `prosto_taxi_driver/android/key.properties.example`

### iOS

Create these files from the examples before iOS builds:

- `app/ios/Flutter/Secrets.xcconfig`
- `prosto_taxi_driver/ios/Flutter/Secrets.xcconfig`

Examples:

- `app/ios/Flutter/Secrets.example.xcconfig`
- `prosto_taxi_driver/ios/Flutter/Secrets.example.xcconfig`

## GitHub Actions

The workflow `.github/workflows/mobile-ci.yml` builds both apps for:

- Android release APK
- iOS release build without code signing

Repository secrets/variables needed:

- `YANDEX_MAPS_KEY`
- `API_BASE_URL` as a repository variable

## Still required before store release

### Infrastructure

- Move the backend from plain HTTP to HTTPS.
- Replace the default `API_BASE_URL` with the production HTTPS endpoint.

### Google Play

- Create one release keystore per app or decide on a shared upload key policy.
- Fill `android/key.properties` locally and later move the values to CI secrets.
- Create app entries in Google Play Console.

### App Store

- Apple Developer account
- App Store Connect apps for both products
- Team access for signing
- Certificates and provisioning profiles

## Recommended next delivery order

1. Create the GitHub repository and push this workspace.
2. Add `YANDEX_MAPS_KEY` and `API_BASE_URL` in GitHub settings.
3. Confirm the final production API domain with HTTPS.
4. Generate Android release keystores.
5. Create the two apps in App Store Connect and Google Play Console.
6. Add signing credentials and distribution automation.
