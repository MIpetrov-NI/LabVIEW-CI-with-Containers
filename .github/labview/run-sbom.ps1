<#
.SYNOPSIS
    Generates a Software Bill of Materials (SBOM) for a LabVIEW project using VIPM CLI
    inside the CI container, then writes summary.json and a safety-net index.html so the
    dashboard always has something to link to.

.DESCRIPTION
    This script locates the VIPM CLI and the project, runs the VIPM SBOM generation
    headlessly, captures the output into sbom.log, and ALWAYS emits an index.html so 
    the dashboard never links to a 404 -- mirroring run-vi-analyzer.ps1 / masscompile.ps1.

    The friendly, navigable report (which embeds / renders the generated docs/SBOM) is
    built afterwards on the runner host by the report builder; this script only needs
    to produce the raw SBOM files, a machine-readable summary.json, and a basic fallback page.

.PARAMETER WorkspaceRoot
    Absolute path inside the container to the project root.
    Default: C:\workspace (the GitHub Actions volume mount point).

.PARAMETER ReportDir
    Directory to write the generated SBOM (under .\doc), sbom.log, summary.json
    and index.html into.

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container. Its year drives the environment setup.

.PARAMETER ProjectPath
    Optional explicit .lvproj to process. When empty the script auto-detects a
    single .lvproj at the workspace root, else the first project found anywhere
    (excluding the .github tooling and ci-out output).

.PARAMETER Title
    Optional document title. Defaults to the repository name (GITHUB_REPOSITORY)
    or the project file name.
#>
param(
    [string]$WorkspaceRoot = 'C:\workspace',
    [string]$ReportDir     = 'C:\report',
    [string]$LabVIEWPath   = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [string]$ProjectPath   = '',
    [string]$Title         = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$PreferredPath) {
  if ($PreferredPath -and (Test-Path $PreferredPath)) {
    return $PreferredPath
  }

  $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
    Where-Object { Test-Path $_ })

  if ($candidates.Count -gt 0) {
    return $candidates[0]
  }

  return $PreferredPath
}

function Resolve-LabVIEWYear([string]$LvPath) {
  if ($LvPath -and ($LvPath -match 'LabVIEW\s+(\d{4})')) { return $Matches[1] }
  if ($env:LABVIEW_VERSION) { return $env:LABVIEW_VERSION }
  return '2026'
}

function Sync-PathFromRegistry {
  try {
    $regPaths = @()
    $machine = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
    $user    = (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -ErrorAction SilentlyContinue).Path
    foreach ($raw in @($machine, $user)) {
      if ($raw) { $regPaths += [System.Environment]::ExpandEnvironmentVariables($raw) }
    }
    $current = @($env:Path -split ';')
    foreach ($entry in (($regPaths -join ';') -split ';')) {
      $e = $entry.Trim()
      if ($e -and ($current -notcontains $e)) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $e
        $current += $e
      }
    }
  } catch {
    Write-Host "  (PATH refresh from registry skipped: $($_.Exception.Message))"
  }
}

function Resolve-VipmCli {
  # Locate VIPM CLI executable (`vipm.exe`). Refreshes environment PATH first,
  # then checks default JKIs / VIPM installation folders.
  Sync-PathFromRegistry

  $cmd = Get-Command 'vipm.exe' -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { $cmd = Get-Command 'vipm' -ErrorAction SilentlyContinue }
  if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }

  $pf  = ${env:ProgramFiles};      if (-not $pf)  { $pf  = 'C:\Program Files' }
  $pfx = ${env:ProgramFiles(x86)}; if (-not $pfx) { $pfx = 'C:\Program Files (x86)' }

  $candidates = @(
    (Join-Path $pfx 'JKI\VI Package Manager\vipm.exe'),
    (Join-Path $pf  'JKI\VI Package Manager\vipm.exe'),
    (Join-Path $pfx 'JKI\VIPM\vipm.exe'),
    (Join-Path $pf  'JKI\VIPM\vipm.exe')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }

  # Fallback bounded recursive search
  foreach ($root in @($pfx, $pf)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
      $hit = Get-ChildItem -LiteralPath $root -Filter 'vipm.exe' -File -Recurse -Depth 4 -ErrorAction SilentlyContinue |
        Select-Object -First 1
      if ($hit) { return $hit.FullName }
    } catch { }
  }
  return ''
}

function Find-Project([string]$Root, [string]$Explicit) {
  if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }

  $rootProj = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.lvproj' -ErrorAction SilentlyContinue |
    Sort-Object Name)
  if ($rootProj.Count -gt 0) { return $rootProj[0].FullName }

  $any = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.lvproj' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '(?i)\\\.github\\' -and $_.FullName -notmatch '(?i)\\ci-out\\' } |
    Sort-Object FullName)
  if ($any.Count -gt 0) { return $any[0].FullName }
  return ''
}

function ConvertTo-RepoRelative([string]$Full, [string]$Base) {
  if (-not $Full) { return '' }
  $b = ($Base.TrimEnd('\') + '\')
  if ($Full.ToLowerInvariant().StartsWith($b.ToLowerInvariant())) {
    return $Full.Substring($b.Length).Replace('\', '/')
  }
  return (Split-Path $Full -Leaf)
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$LvYear      = Resolve-LabVIEWYear $LabVIEWPath
$VipmCli     = Resolve-VipmCli
$Project     = Find-Project $WorkspaceRoot $ProjectPath

$DocDir   = Join-Path $ReportDir 'doc'
$LogFile  = Join-Path $ReportDir 'sbom.log'
$HtmlOut  = Join-Path $ReportDir 'index.html'
$MetaFile = Join-Path $ReportDir 'sbom-meta.json'

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $DocDir    | Out-Null

if (-not $Title) {
  if ($env:GITHUB_REPOSITORY) { $Title = ($env:GITHUB_REPOSITORY -split '/')[-1] }
  elseif ($Project)           { $Title = [System.IO.Path]::GetFileNameWithoutExtension($Project) }
  else                        { $Title = 'LabVIEW Project' }
}

Write-Host "=== VIPM SBOM Generation ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  Project   : $Project"
Write-Host "  Title     : $Title"
Write-Host "  Output    : $DocDir"
Write-Host "  VIPM CLI  : $VipmCli"
Write-Host "  LabVIEW   : $LabVIEWPath ($LvYear)"
Write-Host ""

Set-Content -Path $LogFile -Value "SBOM generation run started $(Get-Date -Format o)" -Encoding UTF8

$Start    = Get-Date
$ExitCode = 0

if (-not $VipmCli) {
  $msg = 'ERROR: VIPM CLI (vipm.exe) was not found in the worker image. Ensure VIPM Pro/CLI is installed in the worker container image.'
  Write-Warning $msg
  Add-Content -Path $LogFile -Value $msg
  $ExitCode = 9
}
elseif (-not $Project) {
  $msg = "ERROR: No .lvproj found under $WorkspaceRoot. VIPM SBOM generates dependencies from a LabVIEW project; add one to the repository or pass -ProjectPath."
  Write-Warning $msg
  Add-Content -Path $LogFile -Value $msg
  $ExitCode = 8
}
else {
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  if (-not $env:LV_RTE_HEADLESS) { $env:LV_RTE_HEADLESS = '1' }

  # Stop lingering instances that might block VIPM execution
  foreach ($proc in @('LabVIEW', 'VI Package Manager', 'VIPM File Handler')) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }

  $SbomOutputFile = Join-Path $DocDir "sbom.json"

  Add-Content -Path $LogFile -Value "LV_RTE_HEADLESS=$($env:LV_RTE_HEADLESS)"
  Add-Content -Path $LogFile -Value "Launching VIPM CLI: $VipmCli sbom generate --project `"$Project`" --labview-version `"$LvYear`" --output-file `"$SbomOutputFile`""
  
  # Invoke VIPM CLI to generate the SBOM for the given LabVIEW project
  & $VipmCli sbom generate --project $Project --labview-version $LvYear --output-file $SbomOutputFile 2>&1 |
    Tee-Object -FilePath $LogFile -Append

  $ExitCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP

  if ($ExitCode -ne 0) {
    Add-Content -Path $LogFile -Value "Post-mortem: VIPM CLI exited with code $ExitCode."
    Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}

$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)

$ErrorActionPreference = 'Continue'

# Inventory generated SBOM artifacts
$DocFiles   = @(Get-ChildItem -LiteralPath $DocDir -Recurse -File -ErrorAction SilentlyContinue)
$JsonFiles  = @($DocFiles | Where-Object { $_.Extension -ieq '.json' -or $_.Extension -ieq '.spdx' } | Sort-Object Length -Descending)
$HtmlFiles  = @($DocFiles | Where-Object { $_.Extension -ieq '.html' -or $_.Extension -ieq '.htm' } | Sort-Object Length -Descending)

$PrimaryKind = 'none'
$PrimaryPath = ''
if ($JsonFiles.Count -gt 0) {
  $PrimaryKind = 'json'
  $PrimaryPath = 'doc/' + (ConvertTo-RepoRelative $JsonFiles[0].FullName $DocDir)
}
elseif ($HtmlFiles.Count -gt 0) {
  $PrimaryKind = 'html'
  $PrimaryPath = 'doc/' + (ConvertTo-RepoRelative $HtmlFiles[0].FullName $DocDir)
}

$Generated  = ($DocFiles.Count -gt 0) -and ($PrimaryKind -ne 'none')
$StatusWord = if ($Generated) { 'passed' } else { 'failed' }

$RelFiles = @($DocFiles | ForEach-Object { 'doc/' + (ConvertTo-RepoRelative $_.FullName $DocDir) } | Sort-Object)

Write-Host ""
Write-Host "=== Result: $StatusWord (files=$($DocFiles.Count) primary=$PrimaryKind exit=$ExitCode duration=${Duration}s) ==="

$Summary = [ordered]@{
    status    = $StatusWord
    title     = $Title
    project   = (ConvertTo-RepoRelative $Project $WorkspaceRoot)
    lvVersion = $LvYear
    primary   = [ordered]@{ kind = $PrimaryKind; path = $PrimaryPath }
    fileCount = $DocFiles.Count
    files     = $RelFiles
    exit      = $ExitCode
    duration  = $Duration
}
[System.IO.File]::WriteAllText(
  $MetaFile,
  ($Summary | ConvertTo-Json -Depth 6),
  [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText(
  (Join-Path $ReportDir 'summary.json'),
  ($Summary | ConvertTo-Json -Depth 6 -Compress),
  [System.Text.UTF8Encoding]::new($false))

# ---- Safety-net HTML report -------------------------------------------------
function Encode-Html([string]$s) {
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
}

$LogText = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($LogText)) { $LogText = '(no output captured)' }
$LogHtml  = Encode-Html $LogText
$ReportTs = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

$StatusLabel = if ($Generated) { 'sbom generated' } else { 'no sbom produced' }
$StatusColor = if ($Generated) { '#2ea043' } else { '#da3633' }

$HdrRepo  = "$env:GITHUB_REPOSITORY"
$HdrSha   = "$env:GITHUB_SHA"
$HdrShort = if ($HdrSha.Length -ge 7) { $HdrSha.Substring(0, 7) } else { $HdrSha }
$HdrCfg   = "window.LVCI={context:'sbom-report',repo:'$HdrRepo',pagesUrl:'../..',sha:'$HdrSha',short:'$HdrShort',platform:'windows',rawUrl:'sbom.log'};"
$TitleHtml = Encode-Html $Title

$Html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>VIPM SBOM - $TitleHtml</title>
  <script>$HdrCfg</script>
  <script src="../../lvci-header.js" defer></script>
  <style>
    *{box-sizing:border-box}
    body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0d1117;color:#e6edf3}
    .wrap{max-width:1180px;margin:0 auto;padding:20px}
    .card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px;margin-bottom:16px}
    h1{margin:0 0 12px;font-size:1.3em}
    .badge{display:inline-block;padding:3px 10px;border-radius:4px;font-weight:700;font-size:.85em;color:#fff;background:$StatusColor}
    .meta{margin-top:10px;font-size:.82em;color:#8b949e;display:flex;flex-wrap:wrap;gap:16px}
    pre{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:14px;font-size:.75em;white-space:pre-wrap;word-break:break-all;overflow-y:auto;max-height:65vh;margin:0}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>VIPM SBOM - $TitleHtml</h1>
      <span class="badge">$StatusLabel</span>
      <div class="meta">
        <span>Date: $ReportTs</span>
        <span>Duration: ${Duration}s</span>
        <span>Files: $($DocFiles.Count)</span>
        <span>Exit: $ExitCode</span>
      </div>
    </div>
    <pre>$LogHtml</pre>
  </div>
</body>
</html>
"@

[System.IO.File]::WriteAllText($HtmlOut, $Html, [System.Text.UTF8Encoding]::new($false))
Write-Host "HTML report -> $HtmlOut"

if ($StatusWord -eq 'failed') { exit 1 } else { exit 0 }