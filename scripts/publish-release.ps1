param(
  [string]$OutputDir = "uup-output"
)

$ErrorActionPreference = "Stop"

if (-not $env:GITHUB_TOKEN) {
  throw "GITHUB_TOKEN is required to publish a release."
}

$env:GH_TOKEN = $env:GITHUB_TOKEN
$maxReleaseAssetBytes = 1900MB

$metadataPath = Join-Path $OutputDir "metadata.json"
if (-not (Test-Path -LiteralPath $metadataPath)) {
  throw "metadata.json not found in $OutputDir"
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$editionPart = ($metadata.editions -join "-").ToLowerInvariant()
if ($metadata.editionInput -eq "ALL") {
  $editionPart = "all"
}

$targetPart = if ($metadata.target) { $metadata.target } else { "custom" }
$tag = "uup-$targetPart-$($metadata.build)-$($metadata.arch)-$($metadata.language)-$editionPart"
$title = "$($metadata.title) $($metadata.arch) $($metadata.language) $($metadata.editionInput)"
$notes = @"
Source: $($metadata.source)
Build: $($metadata.build)
Architecture: $($metadata.arch)
Language: $($metadata.language)
Editions: $($metadata.editions -join ", ")
UUP dump UUID: $($metadata.uuid)

Large ISO files are split into .partNNN files because GitHub Release assets have a per-file size limit. Reassemble them in order before use.
"@

Split-LargeReleaseAssets -Directory $OutputDir -MaxBytes $maxReleaseAssetBytes
Write-Checksums -Directory $OutputDir
Write-ImageInfo -Directory $OutputDir -Metadata $metadata -Tag $tag

$releaseExists = $false
gh release view $tag *> $null
if ($LASTEXITCODE -eq 0) {
  $releaseExists = $true
}

if ($releaseExists) {
  gh release edit $tag --title $title --notes $notes
}
else {
  gh release create $tag --title $title --notes $notes
}

if ($LASTEXITCODE -ne 0) {
  throw "Failed to create or update release $tag"
}

$assets = Get-ChildItem -LiteralPath $OutputDir -File | Where-Object {
  $_.Extension -in ".iso", ".json", ".txt" -or $_.Name -match "\.iso\.part\d+$"
}

if (-not $assets) {
  throw "No release assets found in $OutputDir"
}

$assetPaths = $assets | ForEach-Object { $_.FullName }
gh release upload $tag @assetPaths --clobber
if ($LASTEXITCODE -ne 0) {
  throw "Failed to upload release assets for $tag"
}

"RELEASE_TAG=$tag" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"RELEASE_URL=https://github.com/$env:GITHUB_REPOSITORY/releases/tag/$tag" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
Write-Host "Published release: https://github.com/$env:GITHUB_REPOSITORY/releases/tag/$tag"

function Split-LargeReleaseAssets {
  param(
    [string]$Directory,
    [long]$MaxBytes
  )

  $largeFiles = Get-ChildItem -LiteralPath $Directory -Filter "*.iso" -File | Where-Object {
    $_.Length -gt $MaxBytes
  }

  foreach ($file in $largeFiles) {
    Write-Host "Splitting $($file.Name) into release-sized parts."
    $buffer = New-Object byte[] (8MB)
    $input = [System.IO.File]::OpenRead($file.FullName)

    try {
      $partNumber = 1
      while ($input.Position -lt $input.Length) {
        $partPath = "{0}.part{1:D3}" -f $file.FullName, $partNumber
        $output = [System.IO.File]::Create($partPath)

        try {
          $written = 0L
          while ($written -lt $MaxBytes) {
            $remaining = [Math]::Min($buffer.Length, $MaxBytes - $written)
            $read = $input.Read($buffer, 0, [int]$remaining)
            if ($read -le 0) {
              break
            }

            $output.Write($buffer, 0, $read)
            $written += $read
          }
        }
        finally {
          $output.Dispose()
        }

        $partNumber += 1
      }
    }
    finally {
      $input.Dispose()
    }

    Remove-Item -LiteralPath $file.FullName -Force
  }
}

function Write-Checksums {
  param(
    [string]$Directory
  )

  $checksumPath = Join-Path $Directory "SHA256SUMS.txt"
  $files = Get-ChildItem -LiteralPath $Directory -File | Where-Object {
    $_.Name -ne "SHA256SUMS.txt"
  } | Sort-Object Name

  $lines = foreach ($file in $files) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
  }

  $lines | Out-File -LiteralPath $checksumPath -Encoding utf8
}

function Write-ImageInfo {
  param(
    [string]$Directory,
    [object]$Metadata,
    [string]$Tag
  )

  $imageAssets = Get-ChildItem -LiteralPath $Directory -File | Where-Object {
    $_.Extension -eq ".iso" -or $_.Name -match "\.iso\.part\d+$"
  } | Sort-Object Name

  $assetLines = foreach ($asset in $imageAssets) {
    $hash = Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256
    @"
File: $($asset.Name)
Size bytes: $($asset.Length)
SHA256: $($hash.Hash.ToLowerInvariant())
"@
  }

  $info = @"
UUP Auto Build Image Information

Release tag: $Tag
Title: $($Metadata.title)
Build: $($Metadata.build)
Architecture: $($Metadata.arch)
Language: $($Metadata.language)
Edition input: $($Metadata.editionInput)
Editions: $($Metadata.editions -join ", ")
UUP dump UUID: $($Metadata.uuid)
Source: $($Metadata.source)
Created unix: $($Metadata.createdUnix)
Generated UTC: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss"))Z

Assets
------
$($assetLines -join "`n")

Notes
-----
If the ISO is split into .partNNN files, download every part and concatenate them in numeric order to restore the ISO.
Use SHA256SUMS.txt to verify all release assets.
"@

  $info | Out-File -LiteralPath (Join-Path $Directory "IMAGE_INFO.txt") -Encoding utf8
}
