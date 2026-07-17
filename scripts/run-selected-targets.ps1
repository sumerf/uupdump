param(
  [string]$Target = "win11-25h2",
  [string]$Arch = "amd64",
  [string]$Lang = "zh-cn",
  [ValidateSet("wim", "esd")]
  [string]$ImageFormat = "wim",
  [bool]$IncludeUpdates = $true,
  [bool]$Cleanup = $false,
  [bool]$NetFx3 = $false,
  [switch]$All,
  [switch]$AllowFailures
)

$ErrorActionPreference = "Stop"

$targets = [ordered]@{
  "win11-25h2" = @{
    Search = "Windows 11 25H2"
    Edition = "ALL"
    Arch = @("amd64", "arm64")
  }
  "win11-26h1" = @{
    Search = "Windows 11 26H1"
    Edition = "ALL"
    Arch = @("amd64", "arm64")
  }
  "win11-ltsc-2024" = @{
    Search = "Windows 11 LTSC 2024"
    Edition = "LTSC"
    Arch = @("amd64")
  }
  "win10-22h2" = @{
    Search = "Windows 10 22H2"
    Edition = "ALL"
    Arch = @("amd64", "arm64", "x86")
  }
  "win10-ltsc-2021" = @{
    Search = "Windows 10 LTSC 2021"
    Edition = "LTSC"
    Arch = @("amd64")
  }
}

if ($All -or $Target -eq "all") {
  $selectedTargets = @($targets.Keys)
}
elseif ($targets.Contains($Target)) {
  $selectedTargets = @($Target)
}
else {
  throw "Unknown target '$Target'. Available: all, $($targets.Keys -join ', ')"
}

$failures = @()

foreach ($targetId in $selectedTargets) {
  $config = $targets[$targetId]
  $workDir = "uup-work-$targetId"
  $outputDir = "uup-output-$targetId"

  Write-Host "::group::Build $targetId"
  try {
    if ($config.Arch -notcontains $Arch) {
      throw "Architecture '$Arch' is not available for $targetId. Available: $($config.Arch -join ', ')"
    }

    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue

    $env:UUP_TARGET = $targetId
    $env:UUP_SEARCH = $config.Search
    $env:UUP_ARCH = $Arch
    $env:UUP_LANG = $Lang
    $env:UUP_EDITION = $config.Edition
    $env:UUP_OUT_DIR = $workDir
    $env:UUP_IMAGE_FORMAT = $ImageFormat
    $env:UUP_INCLUDE_UPDATES = if ($IncludeUpdates) { "1" } else { "0" }
    $env:UUP_CLEANUP = if ($Cleanup) { "1" } else { "0" }
    $env:UUP_NETFX3 = if ($NetFx3) { "1" } else { "0" }

    npm run resolve
    if ($LASTEXITCODE -ne 0) {
      throw "Resolve failed for $targetId with exit code $LASTEXITCODE"
    }

    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-uup-build.ps1 -WorkDir $workDir -OutputDir $outputDir -ImageFormat $ImageFormat -IncludeUpdates:$IncludeUpdates -Cleanup:$Cleanup -NetFx3:$NetFx3
    if ($LASTEXITCODE -ne 0) {
      throw "Build failed for $targetId with exit code $LASTEXITCODE"
    }

    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/publish-release.ps1 -OutputDir $outputDir
    if ($LASTEXITCODE -ne 0) {
      throw "Release publish failed for $targetId with exit code $LASTEXITCODE"
    }
  }
  catch {
    Write-Error $_
    $failures += $targetId
    if (-not $AllowFailures) {
      break
    }
  }
  finally {
    Write-Host "::endgroup::"
  }
}

if ($failures.Count -gt 0) {
  throw "Failed targets: $($failures -join ', ')"
}
