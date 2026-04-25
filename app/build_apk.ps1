# Сборка клиентского APK
# Запуск: правый клик -> "Выполнить с PowerShell" или: powershell -File build_apk.ps1
# Требуется: Flutter в PATH (https://docs.flutter.dev/get-started/install/windows)

$ErrorActionPreference = "Stop"
$appDir = $PSScriptRoot

# Проверка Flutter
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Host "Flutter не найден в PATH." -ForegroundColor Red
    Write-Host "Установите Flutter: https://docs.flutter.dev/get-started/install/windows" -ForegroundColor Yellow
    Write-Host "После установки перезапустите терминал и выполните этот скрипт снова." -ForegroundColor Yellow
    exit 1
}

Set-Location $appDir
Write-Host "Сборка APK (клиентское приложение)..." -ForegroundColor Cyan
flutter build apk

if ($LASTEXITCODE -eq 0) {
    $apkPath = Join-Path $appDir "build\app\outputs\flutter-apk\app-release.apk"
    Write-Host ""
    Write-Host "Готово. APK: $apkPath" -ForegroundColor Green
    if (Test-Path $apkPath) {
        explorer.exe (Split-Path $apkPath)
    }
} else {
    exit 1
}
