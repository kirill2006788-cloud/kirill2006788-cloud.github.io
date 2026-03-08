# Create iOS zip archives for Xcode/TestFlight
# Run from project root (folder containing app/ and prosto_taxi_driver/):
#   cd c:\Users\user\CascadeProjects\2048
#   .\deploy_ios\create_ios_zips.ps1

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot | Split-Path -Parent
$outDir = $PSScriptRoot

if (-not (Test-Path "$root\app")) { throw "Folder not found: $root\app" }
if (-not (Test-Path "$root\prosto_taxi_driver")) { throw "Folder not found: $root\prosto_taxi_driver" }

$clientZip = Join-Path $outDir "Trezvyi_voditel_Nol_Promille_client.zip"
$driverZip  = Join-Path $outDir "Nol_Promille_voditel_driver.zip"

function New-SafeProjectZip {
  param(
    [Parameter(Mandatory = $true)] [string] $SourceDir,
    [Parameter(Mandatory = $true)] [string] $ProjectFolderName,
    [Parameter(Mandatory = $true)] [string] $ZipPath
  )

  $tempRoot = Join-Path $outDir "_pack_tmp"
  $stageDir = Join-Path $tempRoot $ProjectFolderName
  if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
  New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

  $excludeDirs = @(
    ".git", ".idea", ".vscode", ".dart_tool", "build", "node_modules",
    "Pods", "DerivedData", ".gradle"
  )
  $excludeFiles = @(
    "Secrets.xcconfig", "key.properties", "*.jks", "*.keystore", "*.p12",
    "*.mobileprovision", "*.cer", "*.pem", ".env", ".env.*"
  )

  $xd = ($excludeDirs | ForEach-Object { "/XD `"$SourceDir\$_`"" }) -join " "
  $xf = ($excludeFiles | ForEach-Object { "/XF `"$SourceDir\$_`"" }) -join " "
  $cmd = "robocopy `"$SourceDir`" `"$stageDir`" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP $xd $xf"
  cmd /c $cmd | Out-Null
  if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed for $SourceDir (exit code $LASTEXITCODE)"
  }

  if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
  Compress-Archive -Path $stageDir -DestinationPath $ZipPath
}

Write-Host "Creating client app zip..."
New-SafeProjectZip -SourceDir "$root\app" -ProjectFolderName "app" -ZipPath $clientZip
Write-Host "  -> $clientZip" -ForegroundColor Green

Write-Host "Creating driver app zip..."
New-SafeProjectZip -SourceDir "$root\prosto_taxi_driver" -ProjectFolderName "prosto_taxi_driver" -ZipPath $driverZip
Write-Host "  -> $driverZip" -ForegroundColor Green

$tempPack = Join-Path $outDir "_pack_tmp"
if (Test-Path $tempPack) { Remove-Item $tempPack -Recurse -Force }

Write-Host "Done. Copy README.md and both zip files to your Mac."
