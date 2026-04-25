# Сборка клиентского AAB с указанным keystore.
# Play Console ожидает ключ с SHA1: 49:E9:D6:23:16:EF:23:3E:C6:84:95:A1:A9:38:A4:33:48:5D:E2:A8
# Использование: .\scripts\build-client-aab-with-keystore.ps1 -KeystorePath "C:\path\to\your.jks" -StorePassword "xxx" -KeyAlias "upload" -KeyPassword "xxx"

param(
  [Parameter(Mandatory = $true)]
  [string]$KeystorePath,

  [Parameter(Mandatory = $true)]
  [string]$StorePassword,

  [Parameter(Mandatory = $true)]
  [string]$KeyPassword,

  [string]$KeyAlias = "upload",

  [switch]$CheckSha1Only
)

$KeystorePath = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KeystorePath)
if (-not (Test-Path $KeystorePath)) {
  Write-Error "Keystore not found: $KeystorePath"
  exit 1
}

# Ожидаемый SHA1 от Play Console для клиента
$expectedSha1 = "49:E9:D6:23:16:EF:23:3E:C6:84:95:A1:A9:38:A4:33:48:5D:E2:A8"

Write-Host "Checking keystore SHA1..."
$keytoolOut = & keytool -list -v -keystore $KeystorePath -storepass $StorePassword -alias $KeyAlias 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Error "keytool failed. Wrong password or alias?"
  exit 1
}
$sha1Line = $keytoolOut | Select-String "SHA1:"
if ($sha1Line) {
  $actualSha1 = ($sha1Line -replace "^\s*SHA1:\s*", "").Trim()
  Write-Host "Keystore SHA1: $actualSha1"
  Write-Host "Play expects:   $expectedSha1"
  if ($actualSha1 -ne $expectedSha1) {
    Write-Warning "SHA1 does not match! Play Console will reject this AAB. Use the keystore that was used for the first upload."
    if (-not $CheckSha1Only) {
      $r = Read-Host "Continue anyway? (y/N)"
      if ($r -ne "y" -and $r -ne "Y") { exit 1 }
    }
  } else {
    Write-Host "SHA1 matches. OK." -ForegroundColor Green
  }
}
if ($CheckSha1Only) {
  exit 0
}

$root = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $root "app\android"
$keyPropsPath = Join-Path $androidDir "key.properties"

# storeFile в key.properties — путь относительно android/ или абсолютный
$storeFileValue = $KeystorePath -replace "\\", "/"
$content = @"
storeFile=$storeFileValue
storePassword=$StorePassword
keyAlias=$KeyAlias
keyPassword=$KeyPassword
"@
Set-Content -Path $keyPropsPath -Value $content -Encoding UTF8
Write-Host "Written $keyPropsPath"

$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
if (-not (Test-Path $env:JAVA_HOME)) {
  $env:JAVA_HOME = "$env:LOCALAPPDATA\Programs\Android Studio\jbr"
}

Set-Location (Join-Path $root "app")
& (Join-Path $root "flutter\bin\flutter.bat") pub get
Set-Location (Join-Path $root "app\android")
& .\gradlew.bat clean bundleRelease
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$aabPath = Join-Path $root "app\build\app\outputs\bundle\release\app-release.aab"
Write-Host ""
Write-Host "Done. AAB: $aabPath" -ForegroundColor Green
