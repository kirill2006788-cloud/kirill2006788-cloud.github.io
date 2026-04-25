param(
  [Parameter(Mandatory = $true)]
  [string]$Path
)

$resolved = Resolve-Path $Path
$bytes = [IO.File]::ReadAllBytes($resolved)
[Convert]::ToBase64String($bytes)
