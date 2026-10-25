<#
.SYNOPSIS
    Installs the LiwaLink relay on Windows Server (2019 or later).

.DESCRIPTION
    Windows counterpart of install-relay.sh. Installs three Windows services:
      liwalink-auth   per-restaurant tokens (liwalink-auth.py on a private Python)
      liwalink-relay  frps, the tunnel server agents connect to (TCP 7000)
      liwalink-caddy  public HTTPS on 80/443 with a certificate per restaurant
    It also adds the liwalink-admin command (in the install folder) and opens
    TCP 80, 443 and 7000 in Windows Firewall.

    Point DNS at this server first: A records for <Domain> and *.<Domain>.

    If IIS already serves websites on 80/443, give the relay its own IP
    address and pass it as -BindAddress. Caddy then listens only on that IP.
    If IIS is still listening on every IP, the installer stops and prints the
    netsh commands that limit IIS to the website's addresses.

    Re-running upgrades in place and keeps the CA, the dashboard password and
    the restaurants. Run from an elevated PowerShell; if scripts are blocked:
        powershell -ExecutionPolicy Bypass -File .\install-relay.ps1 ...

    Windows Defender usually quarantines the frp download, because attackers
    also use frp (seen as Trojan:Win32/Kepavll or HackTool:Win32/Frp). The
    installer then stops and says so. -DefenderExclusion excludes the install
    folder (and the download folder, for the duration of the install) from
    Defender scanning. The alternative is to build and sign frps yourself.

.EXAMPLE
    .\install-relay.ps1 -Domain link.example.com -Email ops@example.com

.EXAMPLE
    .\install-relay.ps1 -Domain link.example.com -Email ops@example.com -DefenderExclusion

.EXAMPLE
    .\install-relay.ps1 -Domain link.example.com -Email ops@example.com -BindAddress 203.0.113.20

.EXAMPLE
    .\install-relay.ps1 -Uninstall
#>
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [ValidatePattern('^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$')]
    [string] $Domain,

    # Let's Encrypt account contact (certificate expiry warnings).
    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [ValidatePattern('^[^\s|@]+@[^\s|@]+$')]
    [string] $Email,

    # Exclude the install folder from Windows Defender so frps.exe is not quarantined.
    [Parameter(ParameterSetName = 'Install')]
    [switch] $DefenderExclusion,

    # The relay's own IP on this server, when IIS keeps 80/443 on another IP.
    [Parameter(ParameterSetName = 'Install')]
    [ValidateScript({ $ip = $null; [ipaddress]::TryParse($_, [ref] $ip) })]
    [string] $BindAddress,

    [Parameter(Mandatory, ParameterSetName = 'Uninstall')]
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the progress bar makes downloads very slow on PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$FrpVersion    = '0.71.1'
$CaddyVersion  = '2.11.7'
$PythonVersion = '3.14.9'
$PythonSha256  = '3c01d7cfc666f746a6f064f60fb2156ab0ec464d3d738ab796371a46a9bb24a2'
$WinSWVersion  = '2.12.0'
$WinSWSha256   = 'b5066b7bbdfba1293e5d15cda3caaea88fbeab35bd5b38c41c913d492aadfc4f'

$InstallDir   = Join-Path $env:ProgramFiles 'LiwaLink\Relay'
$ConfigDir    = Join-Path $env:ProgramData 'LiwaLink\Relay'
$LogDir       = Join-Path $ConfigDir 'logs'
$AdminCmd     = Join-Path $InstallDir 'liwalink-admin.cmd'
$Services     = 'liwalink-caddy', 'liwalink-relay', 'liwalink-auth'  # stop order
$PublicPorts  = 80, 443, 7000
$LocalPorts   = 8080, 7500, 9000  # frps vhost, frps dashboard, liwalink-auth (127.0.0.1 only)
$FirewallRule = 'LiwaLink relay'
$Utf8NoBom    = New-Object System.Text.UTF8Encoding $false

function Assert-FileHash([string] $Path, [string] $Expected, [string] $Algorithm = 'SHA256') {
    $actual = (Get-FileHash -Algorithm $Algorithm -Path $Path).Hash
    if ($actual -ne $Expected) {
        throw "Checksum mismatch for $(Split-Path $Path -Leaf): expected $Expected, got $actual"
    }
}

function Get-PublishedHash([string] $SumsFile, [string] $FileName) {
    $line = Select-String -Path $SumsFile -Pattern (' ' + [regex]::Escape($FileName) + '$') | Select-Object -First 1
    if (-not $line) { throw "No checksum published for $FileName" }
    ($line.Line -split '\s+')[0]
}

# Windows Defender quarantines files it flags as they are written. The download
# then either fails with ERROR_VIRUS_INFECTED, or leaves a file that cannot be
# read and disappears a moment later. frp is the usual victim.
$QuarantineHint = "Windows Defender quarantined it because attackers also use frp. Re-run with -DefenderExclusion to exclude $InstallDir from Defender scanning, or build and sign frps yourself (see the README)."

function Save-Download([string] $Url, [string] $OutFile) {
    $name = Split-Path $OutFile -Leaf
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        $stream = [IO.File]::OpenRead($OutFile)
        $stream.Close()
    } catch [IO.IOException] {
        if ($_.Exception.HResult -ne -2147024671 -and $_.Exception.Message -notmatch 'virus') { throw }
        throw "Could not download ${name}: $QuarantineHint"
    }
    if (-not (Test-Path $OutFile)) { throw "Could not download ${name}: $QuarantineHint" }
}

function Remove-RelayServices {
    foreach ($service in $Services) {
        if (-not (Get-Service -Name $service -ErrorAction SilentlyContinue)) { continue }
        Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
        $wrapper = Join-Path $InstallDir "$service.exe"
        if (Test-Path $wrapper) { & $wrapper uninstall | Out-Null } else { sc.exe delete $service | Out-Null }
        # Windows can keep a deleted service around for a moment.
        for ($i = 0; $i -lt 20 -and (Get-Service -Name $service -ErrorAction SilentlyContinue); $i++) {
            Start-Sleep -Milliseconds 500
        }
    }
}

# Run a program and capture all its output. Windows PowerShell turns redirected
# stderr lines into errors (fatal with ErrorActionPreference=Stop), and Caddy
# logs to stderr even on success.
function Invoke-Program([string] $Program, [string[]] $Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Program @Arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $saved }
    [pscustomobject] @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Assert-Program([string] $What, [string] $Program, [string[]] $Arguments) {
    $result = Invoke-Program $Program $Arguments
    if ($result.ExitCode -ne 0) { throw "$What failed:`n$($result.Output)" }
}

# Fill in a template from this folder; fail if any placeholder is left outside comments.
function Write-Template([string] $Template, [string] $OutFile, [hashtable] $Values) {
    $text = Get-Content -Path (Join-Path $PSScriptRoot $Template) -Raw -Encoding UTF8
    foreach ($key in $Values.Keys) { $text = $text.Replace($key, $Values[$key]) }
    $left = $text -split "`n" | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '__[A-Z_]+__' }
    if ($left) { throw "Unfilled placeholder in ${Template}: $($left | Select-Object -First 1)" }
    [IO.File]::WriteAllText($OutFile, $text, $Utf8NoBom)
}

# Register a WinSW-wrapped service that starts with Windows and restarts on failure.
function Install-RelayService([string] $Id, [string] $Description, [string] $Executable, [string] $Arguments, [hashtable] $Environment = @{}) {
    $wrapper = Join-Path $InstallDir "$Id.exe"
    Copy-Item -Path $WinSWExe -Destination $wrapper -Force
    $envLines = foreach ($key in $Environment.Keys) { "  <env name=`"$key`" value=`"$($Environment[$key])`"/>" }
    $xml = @"
<service>
  <id>$Id</id>
  <name>$Id</name>
  <description>$Description</description>
  <executable>$Executable</executable>
  <arguments>$Arguments</arguments>
$($envLines -join "`n")
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$LogDir</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
</service>
"@
    [IO.File]::WriteAllText((Join-Path $InstallDir "$Id.xml"), $xml, $Utf8NoBom)
    Assert-Program "Registering service $Id" $wrapper @('install')
}

function Wait-Until([scriptblock] $Condition, [int] $Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Seconds 1
    }
    $false
}

if ($Uninstall) {
    Remove-RelayServices
    Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }
    Remove-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue
    Write-Host "LiwaLink relay removed. The CA, restaurants and logs are kept in $ConfigDir."
    Write-Host 'Delete that folder too only if you will never reinstall: agents trust that CA.'
    return
}

$Domain = $Domain.ToLowerInvariant()  # ValidatePattern ignores case

# --- checks -------------------------------------------------------------------------
Write-Host '==> Checking this server'
$netRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
if ($PSVersionTable.PSEdition -ne 'Core' -and (-not $netRelease -or $netRelease -lt 461808)) {
    throw '.NET Framework 4.7.2 or later is required (Windows Server 2019 and later have it).'
}
foreach ($file in 'frps.toml', 'Caddyfile', 'liwalink-auth.py', 'gen-relay-cert.ps1') {
    if (-not (Test-Path (Join-Path $PSScriptRoot $file))) { throw "$file must be next to this script (run it from the repository's relay folder)" }
}

if ($BindAddress -and -not (Get-NetIPAddress -IPAddress $BindAddress -ErrorAction SilentlyContinue)) {
    throw "$BindAddress is not assigned to this server. Add it to the network adapter first (your hosting provider has the details)."
}

Remove-RelayServices  # an earlier install must not count as "port in use"
$listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)

# With -BindAddress, 80/443 only clash when something listens on that IP or on all IPs.
$webPorts = 80, 443
$wildcard = '0.0.0.0', '::'
if ($BindAddress) {
    $httpSysEverywhere = @($listeners | Where-Object {
        $webPorts -contains $_.LocalPort -and $_.OwningProcess -eq 4 -and $wildcard -contains $_.LocalAddress })
    if ($httpSysEverywhere) {
        $keep = @(Get-NetIPAddress -ErrorAction SilentlyContinue | Where-Object {
            $_.IPAddress -ne $BindAddress -and $_.IPAddress -notlike 'fe80*' -and $_.IPAddress -notlike '169.254.*' } |
            ForEach-Object { $_.IPAddress } | Sort-Object -Unique)
        $commands = ($keep | ForEach-Object { "    netsh http add iplisten ipaddress=$_" }) -join "`n"
        throw @"
IIS (HTTP.sys) listens on ports 80/443 of every IP, including $BindAddress.
Limit it to this server's other addresses, restart it, then run this installer again:
$commands
    net stop http /y
    net start w3svc
Also start any other service that 'net stop http' stopped (for example: net start winrm).
The websites keep working on their current IP; expect a few seconds of downtime.
"@
    }
}
$busy = @($listeners | Where-Object {
    if ($BindAddress -and $webPorts -contains $_.LocalPort) { ($wildcard + $BindAddress) -contains $_.LocalAddress }
    else { ($PublicPorts + $LocalPorts) -contains $_.LocalPort }
})
if ($busy) {
    $owners = $busy | Sort-Object LocalPort -Unique | ForEach-Object {
        $owner = if ($_.OwningProcess -eq 4) { 'System/HTTP.sys, usually IIS' } else { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
        "port $($_.LocalPort) ($owner)"
    }
    $hint = if (-not $BindAddress -and ($busy | Where-Object { $webPorts -contains $_.LocalPort })) {
        ' If IIS must keep 80/443, give the relay its own IP and pass -BindAddress (see the README).'
    }
    throw "Already in use: $($owners -join ', '). The relay needs $($PublicPorts -join ', ') (public) and $($LocalPorts -join ', ') (local only).$hint"
}

try {
    $resolved = @(Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
    $wanted = if ($BindAddress) { $BindAddress } else { "this server's public IP" }
    Write-Host "    $Domain resolves to $($resolved -join ', ') (must be $wanted)"
} catch {
    Write-Warning "$Domain does not resolve yet. Add the DNS records; HTTPS certificates can only be issued once it does."
}

# --- downloads ----------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('liwalink-relay-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    if ($DefenderExclusion) {
        Write-Host "==> Excluding $InstallDir from Windows Defender scanning (frps is flagged as a hacking tool)"
        Add-MpPreference -ExclusionPath $InstallDir, $tmp
    }

    Write-Host "==> Downloading frps $FrpVersion, Caddy $CaddyVersion, Python $PythonVersion, WinSW $WinSWVersion"
    $frpZip = "frp_${FrpVersion}_windows_amd64.zip"
    $frpBase = "https://github.com/fatedier/frp/releases/download/v$FrpVersion"
    Save-Download "$frpBase/$frpZip" "$tmp\$frpZip"
    Save-Download "$frpBase/frp_sha256_checksums.txt" "$tmp\frp-sums.txt"
    Assert-FileHash "$tmp\$frpZip" (Get-PublishedHash "$tmp\frp-sums.txt" $frpZip)

    $caddyZip = "caddy_${CaddyVersion}_windows_amd64.zip"
    $caddyBase = "https://github.com/caddyserver/caddy/releases/download/v$CaddyVersion"
    Save-Download "$caddyBase/$caddyZip" "$tmp\$caddyZip"
    Save-Download "$caddyBase/caddy_${CaddyVersion}_checksums.txt" "$tmp\caddy-sums.txt"
    Assert-FileHash "$tmp\$caddyZip" (Get-PublishedHash "$tmp\caddy-sums.txt" $caddyZip) -Algorithm SHA512

    $pythonZip = "python-$PythonVersion-embed-amd64.zip"
    Save-Download "https://www.python.org/ftp/python/$PythonVersion/$pythonZip" "$tmp\$pythonZip"
    Assert-FileHash "$tmp\$pythonZip" $PythonSha256

    $WinSWExe = "$tmp\winsw.exe"
    Save-Download "https://github.com/winsw/winsw/releases/download/v$WinSWVersion/WinSW.NET461.exe" $WinSWExe
    Assert-FileHash $WinSWExe $WinSWSha256

    # --- files ------------------------------------------------------------------------
    Write-Host "==> Installing to $InstallDir"
    if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -Path "$tmp\$frpZip" -DestinationPath "$tmp\frp"
    Copy-Item -Path "$tmp\frp\frp_${FrpVersion}_windows_amd64\frps.exe" -Destination $InstallDir
    Expand-Archive -Path "$tmp\$caddyZip" -DestinationPath "$tmp\caddy"
    Copy-Item -Path "$tmp\caddy\caddy.exe" -Destination $InstallDir
    Expand-Archive -Path "$tmp\$pythonZip" -DestinationPath (Join-Path $InstallDir 'python')
    Copy-Item -Path (Join-Path $PSScriptRoot 'liwalink-auth.py') -Destination $InstallDir
    $python = Join-Path $InstallDir 'python\python.exe'
    $authScript = Join-Path $InstallDir 'liwalink-auth.py'
    $frps = Join-Path $InstallDir 'frps.exe'
    $caddy = Join-Path $InstallDir 'caddy.exe'
    foreach ($exe in $frps, $caddy, $python) {
        if (-not (Test-Path $exe)) { throw "$exe disappeared after copying. $QuarantineHint" }
    }

    # --- config folder: only SYSTEM (the services) and Administrators -----------------
    Write-Host "==> Config in $ConfigDir"
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    icacls.exe $ConfigDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict access to $ConfigDir" }
    New-Item -ItemType Directory -Force -Path $LogDir, (Join-Path $ConfigDir 'public'), (Join-Path $ConfigDir 'caddy') | Out-Null

    & (Join-Path $PSScriptRoot 'gen-relay-cert.ps1') -Domain $Domain -OutDir (Join-Path $ConfigDir 'tls')
    Copy-Item -Path (Join-Path $ConfigDir 'tls\ca.crt') -Destination (Join-Path $ConfigDir 'public\ca.crt') -Force

    $passwordFile = Join-Path $ConfigDir 'dashboard-password.txt'
    if (-not (Test-Path $passwordFile)) {
        $bytes = New-Object byte[] 16
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        [IO.File]::WriteAllText($passwordFile, (($bytes | ForEach-Object { $_.ToString('x2') }) -join ''), $Utf8NoBom)
    }
    $values = @{
        '__DOMAIN__'             = $Domain
        '__EMAIL__'              = $Email
        '__CONFIG_DIR__'         = $ConfigDir -replace '\\', '/'
        '__DASHBOARD_PASSWORD__' = (Get-Content -Path $passwordFile -Raw).Trim()
    }
    $frpsConfig = Join-Path $ConfigDir 'frps.toml'
    $caddyConfig = Join-Path $ConfigDir 'Caddyfile'
    Write-Template 'frps.toml' $frpsConfig $values
    Write-Template 'Caddyfile' $caddyConfig $values
    if ($BindAddress) {
        # Listen only on the relay's IP so IIS keeps 80/443 on the others.
        $caddyText = Get-Content -Path $caddyConfig -Raw
        $caddyText = ([regex] '(?m)^\{[ \t]*$').Replace($caddyText, "{`n`tdefault_bind $BindAddress", 1)
        [IO.File]::WriteAllText($caddyConfig, $caddyText, $Utf8NoBom)
    }
    $registry = Join-Path $ConfigDir 'restaurants.json'

    Assert-Program 'Checking frps.toml' $frps @('verify', '-c', $frpsConfig)
    # Caddy keeps its certificates and state under the config folder, not in SYSTEM's profile.
    $caddyEnv = @{ XDG_DATA_HOME = (Join-Path $ConfigDir 'caddy'); XDG_CONFIG_HOME = (Join-Path $ConfigDir 'caddy') }
    $env:XDG_DATA_HOME = $caddyEnv.XDG_DATA_HOME
    $env:XDG_CONFIG_HOME = $caddyEnv.XDG_CONFIG_HOME
    Assert-Program 'Checking the Caddyfile' $caddy @('validate', '--adapter', 'caddyfile', '--config', $caddyConfig)
    Assert-Program 'Running liwalink-auth.py on the bundled Python' $python @($authScript, '--help')

    # --- admin command ----------------------------------------------------------------
    $adminScript = @"
@echo off
rem Manage restaurants on this relay from an elevated prompt, e.g.:
rem   liwalink-admin add rest-1234 --name "Pizza Place"
"%~dp0python\python.exe" "%~dp0liwalink-auth.py" --registry "$registry" --domain $Domain %*
"@
    [IO.File]::WriteAllText($AdminCmd, ($adminScript -replace "`r?`n", "`r`n"), $Utf8NoBom)

    # --- firewall and services --------------------------------------------------------
    Write-Host "==> Opening TCP $($PublicPorts -join ', ') in Windows Firewall"
    Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound -Protocol TCP -LocalPort $PublicPorts -Action Allow -Profile Any | Out-Null

    Write-Host '==> Starting services'
    Install-RelayService 'liwalink-auth' 'LiwaLink: restaurant tokens (frps plugin and certificate checks)' `
        $python "`"$authScript`" --registry `"$registry`" --domain $Domain serve --listen 127.0.0.1:9000"
    Install-RelayService 'liwalink-relay' 'LiwaLink: tunnel server (frps) that restaurant agents connect to' `
        $frps "-c `"$frpsConfig`""
    Install-RelayService 'liwalink-caddy' 'LiwaLink: public HTTPS for restaurant URLs (Caddy)' `
        $caddy "run --adapter caddyfile --config `"$caddyConfig`"" $caddyEnv

    Start-Service -Name 'liwalink-auth'
    if (-not (Wait-Until { (Invoke-WebRequest -Uri 'http://127.0.0.1:9000/healthz' -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } 15)) {
        throw "liwalink-auth did not start; see $LogDir\liwalink-auth.err.log"
    }
    Start-Service -Name 'liwalink-relay'
    Start-Service -Name 'liwalink-caddy'
    # Check the owner too: with -BindAddress, IIS also listens on 80/443.
    $portOwners = [ordered] @{ 80 = 'caddy'; 443 = 'caddy'; 7000 = 'frps'; 8080 = 'frps' }
    foreach ($entry in $portOwners.GetEnumerator()) {
        $port = $entry.Key
        $owner = $entry.Value
        $listening = Wait-Until {
            Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop |
                Where-Object { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName -eq $owner }
        } 20
        if (-not $listening) { throw "$owner is not listening on port $port; see the logs in $LogDir" }
    }

    Write-Host "==> Checking https://$Domain (first certificate can take a minute)"
    $https = Wait-Until { (Invoke-WebRequest -Uri "https://$Domain/ca.crt" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } 60
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($DefenderExclusion) { Remove-MpPreference -ExclusionPath $tmp -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'LiwaLink relay is installed and running.'
$relayIp = if ($BindAddress) { $BindAddress } else { "this server's public IP" }
if (-not $https) {
    Write-Warning "https://$Domain is not reachable yet. Check that DNS for $Domain and *.$Domain points at $relayIp, and that TCP 80, 443 and 7000 are open in your hosting provider's firewall (or forwarded by the router). Caddy retries on its own; see $LogDir\liwalink-caddy.err.log"
}
Write-Host @"

Add a restaurant (from an elevated PowerShell):
    & '$AdminCmd' add rest-1234 --name "Pizza Place"

Services:   Get-Service liwalink-*
Logs:       $LogDir  (logins and refusals: liwalink-auth.err.log)
Dashboard:  http://127.0.0.1:7500 on this server (user admin, password in $passwordFile)
"@
