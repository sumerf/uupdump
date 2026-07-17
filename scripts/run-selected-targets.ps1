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
  "win10-22h2" = @{
    Search = "Windows 10 22H2"
    Edition = "ALL"
    Arch = @("amd64", "arm64", "x86")
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
$maxBuildAttempts = 5

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

    $skippedBuilds = @()
    $built = $false
    for ($attempt = 1; $attempt -le $maxBuildAttempts; $attempt++) {
      Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue
      $env:UUP_SKIP_BUILDS = $skippedBuilds -join ","

      Write-Host "Build attempt $attempt of $maxBuildAttempts for $targetId. Skipped builds: $env:UUP_SKIP_BUILDS"
      npm run resolve
      if ($LASTEXITCODE -ne 0) {
        throw "Resolve failed for $targetId with exit code $LASTEXITCODE"
      }

      $metadataPath = Join-Path $workDir "metadata.json"
      $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

      pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/run-uup-build.ps1 -WorkDir $workDir -OutputDir $outputDir -ImageFormat $ImageFormat -IncludeUpdates:$IncludeUpdates -Cleanup:$Cleanup -NetFx3:$NetFx3
      if ($LASTEXITCODE -eq 0) {
        $built = $true
        break
      }

      Write-Warning "Build failed for $targetId build $($metadata.build) with exit code $LASTEXITCODE."
      $skippedBuilds += [string]$metadata.build
    }

    if (-not $built) {
      throw "Build failed for $targetId after $maxBuildAttempts attempts. Skipped builds: $($skippedBuilds -join ', ')"
    }

    pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/publish-release.ps1 -OutputDir $outputDir
    if ($LASTEXITCODE -ne 0) {
      throw "Release publish failed for $targetId with exit code $LASTEXITCODE"
    }

    Write-Host "Cleaning workspace for $targetId after release publish."
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outputDir -Recurse -Force -ErrorAction SilentlyContinue
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

if ($failures.Count -gt 0 -and -not $AllowFailures) {
  throw "Failed targets: $($failures -join ', ')"
}
elseif ($failures.Count -gt 0) {
  Write-Warning "Failed targets ignored because AllowFailures is enabled: $($failures -join ', ')"
}
