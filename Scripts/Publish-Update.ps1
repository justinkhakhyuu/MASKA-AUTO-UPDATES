param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('brutal', 'lite', 'external', 'loader')]
    [string]$Channel,

    [string]$Version,

    [string]$ClientDll,

    [string]$NativeLib,

    [string]$NativeInjectorLib,

    [string]$ExternalExe,

    [string]$WinDivertDll,

    [string]$WinDivertSys,

    [string]$LoaderExe,

    [string]$LoaderBuildHeader,

    [switch]$AutoIncrement,

    [switch]$Confirm,

    [switch]$PreviewOnly,

    [switch]$ResolveVersionOnly,

    [switch]$SkipPush,

    [switch]$SkipReleaseNotes,

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Text, [string]$Color = 'Cyan') {
    Write-Host $Text -ForegroundColor $Color
}

function Test-VersionString([string]$Value) {
    $parsed = $null
    return [System.Version]::TryParse($Value.Trim(), [ref]$parsed)
}

function Get-ManifestVersion([string]$ManifestPath, [string]$ChannelName) {
    if (-not (Test-Path $ManifestPath)) {
        return $null
    }

    $data = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    return [string]$data.$ChannelName
}

function Get-VersionCachePath([string]$RepoRoot) {
    return Join-Path $RepoRoot 'updates\version-cache.json'
}

function Get-VersionCache([string]$CachePath, [string]$ChannelName) {
    if (-not (Test-Path $CachePath)) {
        return $null
    }

    $data = Get-Content $CachePath -Raw | ConvertFrom-Json
    return [string]$data.$ChannelName
}

function Set-JsonChannelProperty([object]$Object, [string]$Name, [string]$Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-LoaderEmbeddedVersion([string]$HeaderPath, [string]$VersionValue) {
    if ([string]::IsNullOrWhiteSpace($HeaderPath) -or -not (Test-Path $HeaderPath)) {
        return $false
    }

    $content = Get-Content $HeaderPath -Raw
    $pattern = 'inline constexpr const char\* kLoaderEmbeddedVersion = "[^"]*"'
    $replacement = "inline constexpr const char* kLoaderEmbeddedVersion = `"$($VersionValue.Trim())`""
    if ($content -notmatch $pattern) {
        Write-Host "  Could not find kLoaderEmbeddedVersion in $HeaderPath" -ForegroundColor Yellow
        return $false
    }

    $content = [regex]::Replace($content, $pattern, $replacement)
    Set-Content -Path $HeaderPath -Value $content -Encoding UTF8
    Write-Host "  [OK] loader_build.h -> $($VersionValue.Trim())"
    return $true
}

function Set-VersionCache([string]$CachePath, [string]$ChannelName, [string]$Value) {
    $data = $null
    if (Test-Path $CachePath) {
        $data = Get-Content $CachePath -Raw | ConvertFrom-Json
    }
    else {
        $data = New-Object PSObject
    }

    Set-JsonChannelProperty -Object $data -Name $ChannelName -Value $Value.Trim()
    $data | ConvertTo-Json | Set-Content $CachePath -Encoding UTF8
}

function Read-ReleaseNoteLines([string]$SectionTitle) {
    Write-Host ""
    Write-Host "  $SectionTitle" -ForegroundColor Cyan
    Write-Host "  (one item per line, blank line when done)" -ForegroundColor DarkGray
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = Read-Host "    >"
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $lines.Add($line.Trim()) | Out-Null
    }
    return @($lines)
}

function Read-InteractiveReleaseNotes([string]$ChannelName, [string]$VersionValue) {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Yellow
    Write-Host "  Release notes for $ChannelName $VersionValue" -ForegroundColor Yellow
    Write-Host "  ============================================" -ForegroundColor Yellow
    Write-Host "  Tell users what changed in this update." -ForegroundColor DarkGray
    Write-Host "  Leave a section empty if nothing to report." -ForegroundColor DarkGray

    return [pscustomobject]@{
        added   = @(Read-ReleaseNoteLines 'Added')
        removed = @(Read-ReleaseNoteLines 'Removed')
        fixed   = @(Read-ReleaseNoteLines 'Fixed')
        changed = @(Read-ReleaseNoteLines 'Changed / improved')
    }
}

function Test-ReleaseNotesNonempty($Notes) {
    return ($Notes.added.Count -gt 0) -or ($Notes.removed.Count -gt 0) -or ($Notes.fixed.Count -gt 0) -or ($Notes.changed.Count -gt 0)
}

function Show-ReleaseNotesPreview($Notes) {
    $sections = @(
        @{ Name = 'Added'; Items = $Notes.added; Color = 'Green' },
        @{ Name = 'Removed'; Items = $Notes.removed; Color = 'Red' },
        @{ Name = 'Fixed'; Items = $Notes.fixed; Color = 'Cyan' },
        @{ Name = 'Changed'; Items = $Notes.changed; Color = 'Yellow' }
    )

    $any = $false
    foreach ($section in $sections) {
        if ($section.Items -and $section.Items.Count -gt 0) {
            $any = $true
            Write-Host ""
            Write-Host ("  {0}:" -f $section.Name) -ForegroundColor $section.Color
            foreach ($item in $section.Items) {
                Write-Host ("    - {0}" -f $item)
            }
        }
    }

    if (-not $any) {
        Write-Host ""
        Write-Host "  (no release notes entered)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Get-ChangelogRoot([string]$ChangelogPath) {
    if (-not (Test-Path $ChangelogPath)) {
        return New-Object PSObject
    }

    $raw = Get-Content $ChangelogPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-Object PSObject
    }

    return ($raw | ConvertFrom-Json)
}

function Set-ChannelReleaseNotes([object]$ChangelogRoot, [string]$ChannelName, [string]$VersionValue, $Notes) {
    if (-not ($ChangelogRoot.PSObject.Properties.Name -contains $ChannelName)) {
        $ChangelogRoot | Add-Member -NotePropertyName $ChannelName -NotePropertyValue (New-Object PSObject)
    }

    $channelNode = $ChangelogRoot.$ChannelName
    $notesObj = [pscustomobject]@{
        added   = @($Notes.added)
        removed = @($Notes.removed)
        fixed   = @($Notes.fixed)
        changed = @($Notes.changed)
    }

    if ($channelNode.PSObject.Properties.Name -contains $VersionValue) {
        $channelNode.$VersionValue = $notesObj
    }
    else {
        $channelNode | Add-Member -NotePropertyName $VersionValue -NotePropertyValue $notesObj
    }
}

function Write-ChangelogFile([string]$ChangelogPath, [object]$ChangelogRoot) {
    $ChangelogRoot | ConvertTo-Json -Depth 8 | Set-Content $ChangelogPath -Encoding UTF8
}

function Get-HighestVersion([string[]]$Versions) {
  $best = $null
  foreach ($raw in $Versions) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    if (-not (Test-VersionString $raw)) { continue }
    $candidate = [Version]$raw.Trim()
    if ($null -eq $best -or $candidate -gt $best) {
      $best = $candidate
    }
  }
  if ($null -eq $best) {
    return $null
  }
  return $best.ToString()
}

function Get-NextVersionString([string]$Current) {
  if ([string]::IsNullOrWhiteSpace($Current)) {
    return '1.0.0'
  }

  if (-not (Test-VersionString $Current)) {
    throw "Invalid version '$Current' in cache/manifest."
  }

  $v = [Version]$Current.Trim()
  if ($v.Build -ge 0) {
    return [Version]::new($v.Major, $v.Minor, $v.Build + 1).ToString()
  }

  if ($v.Minor -ge 0) {
    return [Version]::new($v.Major, $v.Minor + 1, 0).ToString()
  }

  return [Version]::new($v.Major + 1, 0, 0).ToString()
}

function Test-VersionAllowed([string]$Current, [string]$New) {
    if ([string]::IsNullOrWhiteSpace($Current)) {
        return [pscustomobject]@{ Ok = $true }
    }

    if (-not (Test-VersionString $New)) {
        return [pscustomobject]@{
            Ok = $false
            Message = "Invalid version '$New'. Use format like 1.0.3"
        }
    }

    $currentVersion = [Version]$Current.Trim()
    $newVersion = [Version]$New.Trim()

    if ($newVersion -eq $currentVersion) {
        return [pscustomobject]@{
            Ok = $false
            Message = "Already on version $Current for '$Channel'. Use a higher version (e.g. $([Version]::new($currentVersion.Major, $currentVersion.Minor, $currentVersion.Build + 1)))."
        }
    }

    if ($newVersion -lt $currentVersion) {
        return [pscustomobject]@{
            Ok = $false
            Message = "Version $New is lower than current $Current. Please upgrade - use a version above $Current."
        }
    }

    return [pscustomobject]@{ Ok = $true }
}

function Show-ProgressLine([string]$Label, [int]$Percent) {
    $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [int]([Math]::Round($pct / 5))
    $bar = ('#' * $filled) + ('-' * (20 - $filled))
    Write-Host ("`r  [{0}] {1,3}%  {2}   " -f $bar, $pct, $Label) -NoNewline
}

function Copy-FileWithProgress([string]$Source, [string]$Destination, [string]$Label) {
    $src = Get-Item -LiteralPath $Source
    $destDir = Split-Path $Destination -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $buffer = New-Object byte[] (1024 * 1024)
    $total = [long]$src.Length
    $copied = [long]0
    $lastPct = -1

    $inStream = [System.IO.File]::OpenRead($src.FullName)
    $outStream = [System.IO.File]::Create($Destination)
    try {
        while ($true) {
            $read = $inStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $outStream.Write($buffer, 0, $read)
            $copied += $read

            $pct = if ($total -gt 0) { [int](($copied * 100L) / $total) } else { 100 }
            if ($pct -ne $lastPct) {
                $lastPct = $pct
                Show-ProgressLine $Label $pct
            }
        }
    }
    finally {
        $outStream.Dispose()
        $inStream.Dispose()
    }

    Show-ProgressLine $Label 100
    Write-Host ""
}

function Invoke-GitQuiet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Invoke-GitPushWithProgress {
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Show-ProgressLine 'Uploading to GitHub' 1
        $exitCode = 0

        & git push --progress origin main 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.ToString()
            } else {
                "$_"
            }

            if ($line -match 'Writing objects:\s+(\d+)%') {
                Show-ProgressLine 'Uploading to GitHub' ([int]$Matches[1])
            }
            elseif ($line -match 'Counting objects:\s+(\d+)%') {
                Show-ProgressLine 'Preparing upload' ([int]$Matches[1])
            }
            elseif ($line -match 'Compressing objects:\s+(\d+)%') {
                Show-ProgressLine 'Compressing' ([int]$Matches[1])
            }
            elseif ($line -match 'Receiving objects:\s+(\d+)%') {
                Show-ProgressLine 'Syncing remote' ([int]$Matches[1])
            }
            elseif ($line -match 'rejected|error:|fatal:') {
                Write-Host ""
                Write-Host "  $line" -ForegroundColor Red
            }
        }

        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Show-ProgressLine 'Uploading to GitHub' 100
            Write-Host ""
        }
        else {
            Write-Host ""
        }

        return $exitCode
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
}

$repo = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $repo 'updates\manifest.json'
$changelogPath = Join-Path $repo 'updates\changelog.json'
$versionCachePath = Get-VersionCachePath $repo

if (-not (Test-Path $manifestPath)) {
    Write-Error "Manifest not found: $manifestPath"
}

$manifestVersion = Get-ManifestVersion $manifestPath $Channel
$cachedVersion = Get-VersionCache $versionCachePath $Channel
$lastPublishedVersion = Get-HighestVersion @($manifestVersion, $cachedVersion)

if ($AutoIncrement) {
    $Version = Get-NextVersionString $lastPublishedVersion
}
elseif ([string]::IsNullOrWhiteSpace($Version)) {
    Write-Host ""
    Write-Host "  Version is required unless you use -AutoIncrement." -ForegroundColor Red
    Write-Host ""
    exit 1
}

if (-not (Test-VersionString $Version)) {
    Write-Host ""
    Write-Host "  Invalid version '$Version'. Use format like 1.0.3" -ForegroundColor Red
    Write-Host ""
    exit 1
}

if ($PreviewOnly) {
    Write-Host ""
    Write-Host "  Channel          : $Channel"
    Write-Host "  Last published   : $(if ($lastPublishedVersion) { $lastPublishedVersion } else { '(none)' })"
    if ($cachedVersion -and $cachedVersion -ne $manifestVersion) {
        Write-Host "    manifest.json  : $(if ($manifestVersion) { $manifestVersion } else { '(none)' })"
        Write-Host "    version-cache  : $cachedVersion"
    }
    if ($AutoIncrement) {
        Write-Host "  Next version     : $Version"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Version)) {
        Write-Host "  Target version   : $Version"
    }
    Write-Host ""
    exit 0
}

if ($ResolveVersionOnly) {
    Write-Output $Version.Trim()
    exit 0
}

$releaseNotes = $null
if (-not $PreviewOnly -and -not $ResolveVersionOnly -and -not $SkipReleaseNotes -and [Environment]::UserInteractive) {
    $releaseNotes = Read-InteractiveReleaseNotes -ChannelName $Channel -VersionValue $Version
    Show-ReleaseNotesPreview -Notes $releaseNotes
    if (Test-ReleaseNotesNonempty $releaseNotes) {
        $notesAnswer = Read-Host "  Save these release notes? [Y/N]"
        if ($notesAnswer -notmatch '^[Yy]') {
            Write-Host "  Release notes skipped." -ForegroundColor Yellow
            $releaseNotes = $null
        }
    }
    else {
        Write-Host "  No release notes entered - skipping changelog." -ForegroundColor DarkGray
        $releaseNotes = $null
    }
    Write-Host ""
}

if ($Confirm -and -not $Yes) {
    Write-Host ""
    Write-Host "  Channel          : $Channel"
    Write-Host "  Last published   : $(if ($lastPublishedVersion) { $lastPublishedVersion } else { '(none)' })"
    if ($cachedVersion -and $cachedVersion -ne $manifestVersion) {
        Write-Host "    manifest.json  : $(if ($manifestVersion) { $manifestVersion } else { '(none)' })"
        Write-Host "    local cache    : $cachedVersion"
    }
    Write-Host "  Next version     : $Version"
    Write-Host ""
    $answer = Read-Host "  Publish $Channel $Version to GitHub? [Y/N]"
    if ($answer -notmatch '^[Yy]') {
        Write-Host ""
        Write-Host "  Cancelled - no update sent." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }
    Write-Host ""
}

$currentVersion = $manifestVersion
$check = Test-VersionAllowed $currentVersion $Version
if (-not $check.Ok) {
    Write-Host ""
    Write-Host "  $($check.Message)" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ClientDll) -and $Channel -ne 'external' -and $Channel -ne 'loader') {
    Write-Error "ClientDll path is required (unless -PreviewOnly)."
}

if ($Channel -eq 'loader') {
    if ([string]::IsNullOrWhiteSpace($LoaderExe)) {
        Write-Error "Loader update needs -LoaderExe path to MaskaXitersLoader.exe"
    }
    if (-not (Test-Path $LoaderExe)) {
        Write-Error "Loader exe not found: $LoaderExe`nBuild the loader Release x64 first."
    }
    $loaderInfo = Get-Item $LoaderExe
    if ($loaderInfo.Length -lt 1MB) {
        Write-Host ""
        Write-Host "  MaskaXitersLoader.exe is too small." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $clientInfo = $loaderInfo
}
elseif ($Channel -ne 'external') {
    if (-not (Test-Path $ClientDll)) {
        Write-Error "Client.dll not found: $ClientDll`nBuild the project first (Compile.bat)."
    }

    $MinClientBytes = 5MB
    $clientInfo = Get-Item $ClientDll
    if ($clientInfo.Length -lt $MinClientBytes) {
        Write-Host ""
        Write-Host "  Client.dll is too small ($([math]::Round($clientInfo.Length / 1KB, 1)) KB)." -ForegroundColor Red
        Write-Host "  Expected a real build (~40+ MB). Run Compile.bat first." -ForegroundColor Yellow
        Write-Host "  Path: $ClientDll" -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($ExternalExe)) {
        Write-Error "External update needs -ExternalExe path to BlackCorpsExternal.exe"
    }
    if ([string]::IsNullOrWhiteSpace($WinDivertDll)) {
        Write-Error "External update needs -WinDivertDll path"
    }
    if ([string]::IsNullOrWhiteSpace($WinDivertSys)) {
        Write-Error "External update needs -WinDivertSys path"
    }
    foreach ($path in @($ExternalExe, $WinDivertDll, $WinDivertSys)) {
        if (-not (Test-Path $path)) {
            Write-Error "File not found: $path`nBuild EXTERNAL X ESP Release x64 first."
        }
    }
    $clientInfo = Get-Item $ExternalExe
    if ($clientInfo.Length -lt 512KB) {
        Write-Host ""
        Write-Host "  BlackCorpsExternal.exe is too small." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
}

if ($Channel -eq 'brutal' -and -not [string]::IsNullOrWhiteSpace($NativeLib)) {
    if (-not (Test-Path $NativeLib)) {
        Write-Error "Native lib not found: $NativeLib"
    }

    $nativeInfo = Get-Item $NativeLib
    if ($nativeInfo.Length -lt 50KB) {
        Write-Host ""
        Write-Host "  libTERMINALX999Cheats.so is too small." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($NativeInjectorLib)) {
        Write-Error "Brutal update with native libs needs -NativeInjectorLib path to libinjectEmulator.so"
    }

    if (-not (Test-Path $NativeInjectorLib)) {
        Write-Error "Injector lib not found: $NativeInjectorLib"
    }

    $injectorInfo = Get-Item $NativeInjectorLib
    if ($injectorInfo.Length -lt 50KB) {
        Write-Host ""
        Write-Host "  libinjectEmulator.so is too small." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
}

Write-Host ""
Write-Step "  MASKA XITERS - publish $Channel update"
Write-Host ""
Write-Host "  Current : $(if ($currentVersion) { $currentVersion } else { '(none)' })"
Write-Host "  New     : $Version"
Write-Host ("  Client  : {0:N1} MB" -f ($clientInfo.Length / 1MB))
if ($Channel -eq 'brutal' -and -not [string]::IsNullOrWhiteSpace($NativeLib)) {
    Write-Host ("  Native  : {0:N1} MB (cheat)" -f ((Get-Item $NativeLib).Length / 1MB))
    Write-Host ("  Inject  : {0:N1} MB" -f ((Get-Item $NativeInjectorLib).Length / 1MB))
}
Write-Host ""

if ($Channel -eq 'brutal') {
    $clientDest = Join-Path $repo 'payloads\brutal\Client.dll'
    Copy-FileWithProgress -Source $ClientDll -Destination $clientDest -Label 'Copying Client.dll'
    Write-Host ("  [OK] Client.dll ({0:N1} MB)" -f ((Get-Item $clientDest).Length / 1MB))

    if (-not [string]::IsNullOrWhiteSpace($NativeLib) -and -not [string]::IsNullOrWhiteSpace($NativeInjectorLib)) {
        $nativeDest = Join-Path $repo 'payloads\brutal\Libraries\libTERMINALX999Cheats.so'
        $injectorDest = Join-Path $repo 'payloads\brutal\Libraries\libinjectEmulator.so'
        New-Item -ItemType Directory -Force -Path (Split-Path $nativeDest -Parent) | Out-Null
        Copy-FileWithProgress -Source $NativeLib -Destination $nativeDest -Label 'Copying libTERMINALX999Cheats.so'
        Copy-FileWithProgress -Source $NativeInjectorLib -Destination $injectorDest -Label 'Copying libinjectEmulator.so'
        Write-Host ("  [OK] libTERMINALX999Cheats.so ({0:N1} MB)" -f ((Get-Item $nativeDest).Length / 1MB))
        Write-Host ("  [OK] libinjectEmulator.so ({0:N1} MB)" -f ((Get-Item $injectorDest).Length / 1MB))
    }
}
elseif ($Channel -eq 'external') {
    $exeDest = Join-Path $repo 'payloads\external\BlackCorpsExternal.exe'
    $dllDest = Join-Path $repo 'payloads\external\WinDivert.dll'
    $sysDest = Join-Path $repo 'payloads\external\WinDivert64.sys'

    Copy-FileWithProgress -Source $ExternalExe -Destination $exeDest -Label 'Copying BlackCorpsExternal.exe'
    Copy-FileWithProgress -Source $WinDivertDll -Destination $dllDest -Label 'Copying WinDivert.dll'
    Copy-FileWithProgress -Source $WinDivertSys -Destination $sysDest -Label 'Copying WinDivert64.sys'
    Write-Host ("  [OK] BlackCorpsExternal.exe ({0:N1} MB)" -f ((Get-Item $exeDest).Length / 1MB))
    Write-Host ("  [OK] WinDivert.dll ({0:N1} MB)" -f ((Get-Item $dllDest).Length / 1MB))
    Write-Host ("  [OK] WinDivert64.sys ({0:N1} MB)" -f ((Get-Item $sysDest).Length / 1MB))
}
elseif ($Channel -eq 'loader') {
    $loaderDest = Join-Path $repo 'payloads\loader\MaskaXitersLoader.exe'
    if ($LoaderBuildHeader) {
        Set-LoaderEmbeddedVersion -HeaderPath $LoaderBuildHeader -VersionValue $Version | Out-Null
    }
    Copy-FileWithProgress -Source $LoaderExe -Destination $loaderDest -Label 'Copying MaskaXitersLoader.exe'
    Write-Host ("  [OK] MaskaXitersLoader.exe ({0:N1} MB)" -f ((Get-Item $loaderDest).Length / 1MB))
}
else {
    $clientDest = Join-Path $repo 'payloads\lite\Client.dll'
    Copy-FileWithProgress -Source $ClientDll -Destination $clientDest -Label 'Copying Client.dll'
    Write-Host ("  [OK] Client.dll ({0:N1} MB)" -f ((Get-Item $clientDest).Length / 1MB))
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
Set-JsonChannelProperty -Object $manifest -Name $Channel -Value $Version.Trim()
$manifest | ConvertTo-Json | Set-Content $manifestPath -Encoding UTF8
Set-VersionCache $versionCachePath $Channel $Version
Write-Host "  [OK] manifest.json -> $Version"
Write-Host "  [OK] version-cache.json -> $Version"

if ($releaseNotes) {
    $changelog = Get-ChangelogRoot $changelogPath
    Set-ChannelReleaseNotes -ChangelogRoot $changelog -ChannelName $Channel -VersionValue $Version.Trim() -Notes $releaseNotes
    Write-ChangelogFile -ChangelogPath $changelogPath -ChangelogRoot $changelog
    Write-Host "  [OK] changelog.json -> $Channel $Version"
}
Write-Host ""

if ($SkipPush) {
    Write-Step "  Skipped git push (-SkipPush)." "Yellow"
    exit 0
}

Push-Location $repo
try {
    $add = Invoke-GitQuiet -Arguments @('add', 'payloads', 'updates/manifest.json', 'updates/version-cache.json', 'updates/changelog.json')
    if ($add.ExitCode -ne 0) {
        Write-Host "  git add failed:" -ForegroundColor Red
        Write-Host $add.StdErr
        exit 1
    }

    $commitMsg = "Publish $Channel $Version"
    if ($releaseNotes) {
        $summaryParts = @()
        if ($releaseNotes.added.Count -gt 0) { $summaryParts += "+$($releaseNotes.added.Count) added" }
        if ($releaseNotes.removed.Count -gt 0) { $summaryParts += "-$($releaseNotes.removed.Count) removed" }
        if ($releaseNotes.fixed.Count -gt 0) { $summaryParts += "$($releaseNotes.fixed.Count) fixed" }
        if ($releaseNotes.changed.Count -gt 0) { $summaryParts += "$($releaseNotes.changed.Count) changed" }
        if ($summaryParts.Count -gt 0) {
            $commitMsg += " (" + ($summaryParts -join ', ') + ")"
        }
    }
    $commit = Invoke-GitQuiet -Arguments @(
        '-c', 'user.name=justinkhakhyuu',
        '-c', 'user.email=justinkhakhyuu@users.noreply.github.com',
        'commit', '-m', $commitMsg
    )

    if ($commit.ExitCode -eq 0) {
        Write-Host "  [OK] commit: $commitMsg"
    }
    else {
        $combined = ($commit.StdOut + $commit.StdErr)
        if ($combined -match 'nothing to commit') {
            Write-Host "  [OK] nothing new to commit (files already current)"
        }
        else {
            Write-Host "  Commit warning:" -ForegroundColor Yellow
            if ($commit.StdOut) { Write-Host $commit.StdOut }
            if ($commit.StdErr) { Write-Host $commit.StdErr }
        }
    }

    Write-Host ""
    $pushCode = Invoke-GitPushWithProgress
    if ($pushCode -ne 0) {
        Write-Host "  Git push failed (exit $pushCode)." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Step "  Published $Channel $Version to GitHub." "Green"
    Write-Host "  Users can click CHECK FOR UPDATES in the loader."
    Write-Host ""
}
finally {
    Pop-Location
}
