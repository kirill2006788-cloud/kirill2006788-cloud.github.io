param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("client", "driver")]
  [string]$App,

  [Parameter(Mandatory = $true)]
  [string]$StorePassword,

  [Parameter(Mandatory = $true)]
  [string]$KeyPassword,

  [string]$KeyAlias = "upload"
)

$root = Split-Path -Parent $PSScriptRoot
if ($App -eq "client") {
  $androidDir = Join-Path $root "app\android"
  $secretPrefix = "ANDROID_CLIENT"
} else {
  $androidDir = Join-Path $root "prosto_taxi_driver\android"
  $secretPrefix = "ANDROID_DRIVER"
}

$keystorePath = Join-Path $androidDir "release-keystore.jks"

keytool -genkeypair `
  -v `
  -keystore $keystorePath `
  -storepass $StorePassword `
  -alias $KeyAlias `
  -keypass $KeyPassword `
  -keyalg RSA `
  -keysize 2048 `
  -validity 10000 `
  -dname "CN=Prosto Taxi, OU=Mobile, O=Prosto Taxi, L=Moscow, S=Moscow, C=RU"

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath))

Write-Host ""
Write-Host "Add these GitHub secrets:"
Write-Host "$secretPrefix`_KEYSTORE_BASE64=$base64"
Write-Host "$secretPrefix`_KEYSTORE_PASSWORD=$StorePassword"
Write-Host "$secretPrefix`_KEY_ALIAS=$KeyAlias"
Write-Host "$secretPrefix`_KEY_PASSWORD=$KeyPassword"
