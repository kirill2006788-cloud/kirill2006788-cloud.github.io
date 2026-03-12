# Сборка клиентского и водительского приложений для Android
# Запуск: в PowerShell из папки 2048: .\build_android.ps1

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot

# 1) Ищем flutter.bat
$flutterPaths = @(
    "C:\Users\user\CascadeProjects\2048\flutter\bin\flutter.bat",
    "C:\flutter\bin\flutter.bat",
    "C:\src\flutter\bin\flutter.bat",
    "$env:USERPROFILE\flutter\bin\flutter.bat",
    "$env:LOCALAPPDATA\flutter\bin\flutter.bat",
    "$env:USERPROFILE\fvm\default\bin\flutter.bat",
    "$env:USERPROFILE\development\flutter\bin\flutter.bat"
)

$flutterCmd = $null
foreach ($p in $flutterPaths) {
    if (Test-Path $p) {
        $flutterCmd = $p
        break
    }
}

if (-not $flutterCmd) {
    $where = (Get-Command flutter -ErrorAction SilentlyContinue).Source
    if ($where) { $flutterCmd = "flutter" }
}

if (-not $flutterCmd) {
    Write-Host "Flutter не найден. Укажите путь в скрипте или добавьте Flutter в PATH." -ForegroundColor Red
    exit 1
}

Write-Host "Используется: $flutterCmd" -ForegroundColor Green

function Invoke-Flutter {
    param([string]$Dir, [string]$Name)
    Set-Location $Dir
    Write-Host "`n--- $Name ---" -ForegroundColor Cyan
    if ($flutterCmd -eq "flutter") {
        & flutter pub get
        & flutter build apk
    } else {
        & $flutterCmd pub get
        & $flutterCmd build apk
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Invoke-Flutter -Dir "$projectRoot\app" -Name "Клиент (app)"
Invoke-Flutter -Dir "$projectRoot\prosto_taxi_driver" -Name "Водитель (prosto_taxi_driver)"

Set-Location $projectRoot
Write-Host "`nГотово. APK:" -ForegroundColor Green
Write-Host "  Клиент:   app\build\app\outputs\flutter-apk\app-release.apk"
Write-Host "  Водитель: prosto_taxi_driver\build\app\outputs\flutter-apk\app-release.apk"
