param(
  [string]$WorkDir = "uup-work",
  [string]$OutputDir = "uup-output"
)

$ErrorActionPreference = "Stop"

function Patch-UupScripts {
  param(
    [string]$Root
  )

  $ariaScripts = Get-ChildItem -LiteralPath $Root -Recurse -Filter "get_aria2.ps1" -File
  foreach ($script in $ariaScripts) {
    $content = Get-Content -LiteralPath $script.FullName -Raw
    if ($content -notmatch "Get-FileHash") {
      continue
    }

    $shim = @'
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
  function Get-FileHash {
    param(
      [string]$Path,
      [string]$Algorithm = "SHA256"
    )

    $resolved = Resolve-Path -LiteralPath $Path
    $stream = [System.IO.File]::OpenRead($resolved)
    try {
      $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
      $hashBytes = $hashAlgorithm.ComputeHash($stream)
      $hash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
      [pscustomobject]@{
        Algorithm = $Algorithm
        Hash = $hash
        Path = $resolved.Path
      }
    }
    finally {
      $stream.Dispose()
    }
  }
}

'@

    Set-Content -LiteralPath $script.FullName -Value ($shim + $content) -Encoding UTF8
    Write-Host "Patched PowerShell hash compatibility in $($script.FullName)"
  }
}

$workPath = Resolve-Path -LiteralPath $WorkDir
$metadataPath = Join-Path $workPath "metadata.json"
if (-not (Test-Path -LiteralPath $metadataPath)) {
  throw "metadata.json not found. Run npm run resolve first."
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$packagePath = Join-Path $PWD $metadata.zipPath
if (-not (Test-Path -LiteralPath $packagePath)) {
  throw "UUP script package not found: $packagePath"
}

$extractPath = Join-Path $workPath "package"
if (Test-Path -LiteralPath $extractPath) {
  Remove-Item -LiteralPath $extractPath -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
Expand-Archive -LiteralPath $packagePath -DestinationPath $extractPath -Force

$converter = Get-ChildItem -LiteralPath $extractPath -Recurse -Filter "uup_download_windows.cmd" | Select-Object -First 1
if (-not $converter) {
  throw "uup_download_windows.cmd was not found in the package."
}

Patch-UupScripts -Root $extractPath

Push-Location -LiteralPath $converter.DirectoryName
try {
  cmd.exe /c "`"$($converter.FullName)`""
  if ($LASTEXITCODE -ne 0) {
    throw "UUP converter failed with exit code $LASTEXITCODE"
  }
}
finally {
  Pop-Location
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$isoFiles = Get-ChildItem -LiteralPath $converter.DirectoryName -Filter "*.iso" -File
if (-not $isoFiles) {
  throw "Build completed but no ISO was produced."
}

foreach ($iso in $isoFiles) {
  Move-Item -LiteralPath $iso.FullName -Destination (Join-Path $OutputDir $iso.Name) -Force
}

Copy-Item -LiteralPath $metadataPath -Destination (Join-Path $OutputDir "metadata.json") -Force
Get-ChildItem -LiteralPath $OutputDir -File | Format-Table Name, Length
