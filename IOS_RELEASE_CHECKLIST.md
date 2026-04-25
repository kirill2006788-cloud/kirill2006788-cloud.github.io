# iOS Release Checklist

This project now contains the code-side iOS push groundwork for:

- `ru.prostotaxi.client`
- `ru.prostotaxi.driver`

## What is already prepared in code

- iOS bundle identifiers are set
- `Runner.entitlements` files are added for both apps
- APNs token registration is implemented in both `AppDelegate.swift` files
- Flutter now sends iOS push tokens to the backend
- backend endpoints exist:
  - `POST /api/client/push-token`
  - `POST /api/driver/push-token`
- driver local notifications now include iOS configuration

## Apple account setup

You still need these items in Apple:

- Apple Developer account
- App Store Connect access
- permission to manage Certificates, Identifiers & Profiles

## App Store Connect apps

Create two apps in App Store Connect:

- client app -> bundle id `ru.prostotaxi.client`
- driver app -> bundle id `ru.prostotaxi.driver`

## Certificates and profiles

Prepare:

- one iOS distribution certificate exported as `.p12`
- password for the `.p12`
- provisioning profile for `ru.prostotaxi.client`
- provisioning profile for `ru.prostotaxi.driver`
- Apple Team ID

## App Store Connect API key

Create an App Store Connect API key and collect:

- `Issuer ID`
- `Key ID`
- `.p8` private key

## GitHub secrets for iOS CI/CD

Add these repository secrets later:

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_API_KEY_BASE64`
- `IOS_P12_BASE64`
- `IOS_P12_PASSWORD`
- `IOS_TEAM_ID`
- `IOS_CLIENT_PROFILE_BASE64`
- `IOS_DRIVER_PROFILE_BASE64`

When these are present, the GitHub workflow can export a signed `IPA` artifact for each app.

## Push notifications in Apple

For both app identifiers in Apple Developer:

- enable `Push Notifications`
- ensure the provisioning profiles are regenerated after enabling push

For driver app also confirm background capabilities:

- `Background Modes`
- `Location updates`
- `Remote notifications`

## Still not guaranteed without external setup

Even after the code changes, real production iOS pushes still depend on:

- valid Apple signing
- APNs-enabled app identifiers
- provisioning profiles with push enabled
- production backend/APNs delivery credentials
- production `HTTPS` API URL
