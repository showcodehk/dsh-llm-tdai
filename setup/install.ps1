<#
.SYNOPSIS
    Install the dsh-llm-tdai plugin into a DSH profile.

.DESCRIPTION
    Run it straight from the repository:

        irm https://raw.githubusercontent.com/showcodehk/dsh-llm-tdai/main/setup/install.ps1 | iex

    Because that form evaluates the script in the current session, this file uses
    `throw` rather than `exit` on failure: `exit` would close the caller's shell.

    Environment variables:
      DSH_PROFILE         profile to install into            (default: desktop)
      DSH_BIN             path to the dsh CLI                (default: auto-detect)
      DSH_LLM_TDAI_URL    download URL for the tarball       (default: latest release)
      DSH_LLM_TDAI_PKG    local tarball, skips the download  (for offline installs)
#>

$ErrorActionPreference = 'Stop'

# Where the release lives. Moving hosts means editing this block only - the three
# install commands stay identical.
$Host_   = 'https://github.com'
$Owner   = 'showcodehk'
$Repo    = 'dsh-llm-tdai'
$Package = 'dsh-llm-tdai'

# The `latest/download` alias is a permanent URL: it resolves to the asset of the
# newest non-draft, non-prerelease release. That is why the published asset keeps
# the same name in every release - the alias matches the name exactly, so a
# version-carrying name would change the URL on every bump.
$ReleaseUrl = if ($env:DSH_LLM_TDAI_URL) {
    $env:DSH_LLM_TDAI_URL
} else {
    "$Host_/$Owner/$Repo/releases/latest/download/$Package.tgz"
}

$ProfileName = if ($env:DSH_PROFILE) { $env:DSH_PROFILE } else { 'desktop' }
# Fixed name on disk so the recorded `file:` dependency never dangles when a new
# version appears; re-installs overwrite it in place.
$CacheName = "$Package.tgz"

# Windows PowerShell 5.1 can default to TLS 1.0/1.1, which GitHub and most
# modern hosts reject with "the underlying connection was closed". Opt in before
# any web call; on PowerShell 6+ this is unnecessary but harmless.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # older runtime without Tls12; the download will fail with a clear message
    }
}

# A self-signed host needs the check skipped. Off by default; GitHub does not
# need it, so this only matters for a mirrored or internal staging deployment.
$insecure = $env:DSH_LLM_TDAI_INSECURE -eq '1'
if ($insecure) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Find-Dsh {
    if ($env:DSH_BIN) {
        if (-not (Test-Path -LiteralPath $env:DSH_BIN)) {
            throw "DSH_BIN is set but does not exist: $($env:DSH_BIN)"
        }
        return $env:DSH_BIN
    }
    $onPath = Get-Command dsh -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $suffix = 'resources\runtime\cli\bin\dsh.cmd'
    $candidates = @(
        "C:\DeepSeekHarness\$suffix",
        "D:\DeepSeekHarness\$suffix",
        (Join-Path $env:ProgramFiles "DeepSeekHarness\$suffix"),
        (Join-Path $env:LOCALAPPDATA "Programs\DeepSeekHarness\$suffix")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "dsh CLI not found. Add it to PATH, or set DSH_BIN to the full path of dsh.cmd."
}

$dsh = Find-Dsh

# `--profile` refuses to run while the desktop host is open.
$running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'DeepSeek' }
if ($running) {
    throw "DeepSeekHarness is still running. Quit it completely (including the tray icon), then run this again."
}

# The profile records a `file:` dependency pointing at wherever the tarball
# lived, so it must outlive this script. A fixed cache path also keeps
# re-installs predictable; a temp directory would be deleted and break the next
# pnpm run.
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$cache = if ($env:DSH_LLM_TDAI_CACHE) {
    $env:DSH_LLM_TDAI_CACHE
} else {
    Join-Path $dshHome '.plugin-cache'
}
New-Item -ItemType Directory -Path $cache -Force | Out-Null

$tgz = Join-Path $cache $CacheName

# curl.exe ships with Windows 10 1803+. Prefer it: .NET Framework's TLS stack
# rejects some hosts that curl negotiates with happily, and the failure surfaces
# as the unhelpful "the underlying connection was closed".
$curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue

function Save-Remote([string]$address, [string]$dest) {
    if ($curlCmd) {
        $argList = @('-fsSL')
        if ($insecure) { $argList += '-k' }
        $argList += @($address, '-o', $dest)
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $curlCmd.Source @argList 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($code -ne 0) { throw "download failed: $address" }
        return
    }
    Invoke-WebRequest -Uri $address -OutFile $dest -UseBasicParsing
}

if ($env:DSH_LLM_TDAI_PKG) {
    Write-Host "using local package: $($env:DSH_LLM_TDAI_PKG)"
    $srcFull = [System.IO.Path]::GetFullPath($env:DSH_LLM_TDAI_PKG)
    $dstFull = [System.IO.Path]::GetFullPath($tgz)
    if ($srcFull -ne $dstFull) {
        Copy-Item -LiteralPath $srcFull -Destination $tgz -Force
    }
} else {
    Write-Host "downloading $ReleaseUrl"
    Save-Remote $ReleaseUrl $tgz
}

if (-not (Test-Path -LiteralPath $tgz) -or (Get-Item -LiteralPath $tgz).Length -eq 0) {
    throw "download produced no data: $tgz"
}

# Remove first: pnpm matches a `file:` dependency by path + version, so
# re-adding the same asset would report "Already up to date" and keep the
# previous copy. Removal is best-effort — a fresh profile has nothing to remove,
# and pnpm exits non-zero for that, which `$ErrorActionPreference = 'Stop'`
# would otherwise turn into a terminating error.
Write-Host 'removing any previous copy'
try {
    & $dsh plugin --profile $ProfileName remove $Package 2>&1 | Out-Null
} catch {
    # nothing installed yet
}

# `remove` leaves a symlink behind for directory installs; pnpm keeps it.
$stale = Join-Path $dshHome "profiles\$ProfileName\node_modules\$Package"
if (Test-Path -LiteralPath $stale) {
    Remove-Item -LiteralPath $stale -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "installing into profile '$ProfileName'"
# pnpm reports progress on stderr, which `Stop` would treat as failure; judge by
# the exit code instead, or a successful install looks like an error.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$addOutput = & $dsh plugin --profile $ProfileName add $tgz 2>&1
$addExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($addExit -ne 0) {
    $addOutput | ForEach-Object { Write-Host $_ }
    throw "dsh plugin add failed with exit code $addExit"
}

Write-Host ''
Write-Host 'done. Start DeepSeekHarness and pick the provider that routes to your memory proxy.'
