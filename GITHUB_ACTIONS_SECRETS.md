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

## Google Play automatic upload

If you want GitHub Actions to upload the signed `AAB` automatically to Google Play `internal` track, add:

- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
  - raw JSON of the Google Play service account key with access to both apps

When this secret is present together with the Android signing secrets, the workflow will:

- build signed `AAB`
- upload the bundle to Google Play `internal`

## iOS distribution

The workflow now supports optional signed `IPA` export when the iOS signing secrets are present.

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

Helper script in this repo:

```powershell
.\scripts\encode-file-base64.ps1 -Path "C:\path\to\file"
```

### macOS/Linux

```bash
base64 -i /path/to/file
```

## What the current workflow does

- Builds both Flutter apps on push, PR, or manual run
- Builds Android release APK for both apps
- Builds Android signed AAB when Android signing secrets are present
- Uploads signed Android AAB to Google Play `internal` when `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is present
- Builds iOS release without code signing for both apps
- Exports signed iOS IPA when iOS signing secrets are present

## Android keystore helper

Windows helper script:

```powershell
.\scripts\create-android-keystore.ps1 -App client -StorePassword "..." -KeyPassword "..."
.\scripts\create-android-keystore.ps1 -App driver -StorePassword "..." -KeyPassword "..."
```

The script creates `release-keystore.jks` in the app's `android` folder and prints the exact GitHub secret names to add.

## What is still blocked outside GitHub

- Production `HTTPS` backend endpoint
- Google Play app entries
- Google Play service account with API access
- Apple Developer / App Store Connect setup
- iOS certificates and provisioning profiles
