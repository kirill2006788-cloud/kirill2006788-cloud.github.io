# GitHub Actions Secrets

This repository already uses:

- secret `YANDEX_MAPS_KEY`
- variable `API_BASE_URL`

## Required now

### Repository variables

- `API_BASE_URL`
  - current value: `http://194.67.84.155`
  - should be replaced with the production `https://...` URL before store release

### Repository secrets

- `YANDEX_MAPS_KEY`
  - shared by both apps in the current setup

## Android release signing

Add these secrets when you are ready to build signed Play Store bundles.

### Client app

- `ANDROID_CLIENT_KEYSTORE_BASE64`
  - base64 of the client upload keystore `.jks`
- `ANDROID_CLIENT_KEYSTORE_PASSWORD`
- `ANDROID_CLIENT_KEY_ALIAS`
- `ANDROID_CLIENT_KEY_PASSWORD`

### Driver app

- `ANDROID_DRIVER_KEYSTORE_BASE64`
  - base64 of the driver upload keystore `.jks`
- `ANDROID_DRIVER_KEYSTORE_PASSWORD`
- `ANDROID_DRIVER_KEY_ALIAS`
- `ANDROID_DRIVER_KEY_PASSWORD`

When these secrets are present, the workflow will also build:

- signed `AAB` for `app`
- signed `AAB` for `prosto_taxi_driver`

## iOS distribution

These are not wired into the workflow yet because store signing depends on Apple account setup, but this is the next exact set to prepare.

### App Store Connect API

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_API_KEY_BASE64`
  - base64 of the `.p8` App Store Connect API key

### Apple signing

- `IOS_P12_BASE64`
  - base64 of the signing certificate `.p12`
- `IOS_P12_PASSWORD`
- `IOS_TEAM_ID`

### Provisioning profiles

- `IOS_CLIENT_PROFILE_BASE64`
  - base64 of the client `.mobileprovision`
- `IOS_DRIVER_PROFILE_BASE64`
  - base64 of the driver `.mobileprovision`

## How to convert files to base64

### Windows PowerShell

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\file"))
```

### macOS/Linux

```bash
base64 -i /path/to/file
```

## What the current workflow does

- Builds both Flutter apps on push, PR, or manual run
- Builds Android release APK for both apps
- Builds Android signed AAB when Android signing secrets are present
- Builds iOS release without code signing for both apps

## What is still blocked outside GitHub

- Production `HTTPS` backend endpoint
- Google Play app entries
- Apple Developer / App Store Connect setup
- iOS certificates and provisioning profiles
