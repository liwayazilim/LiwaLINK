<#
.SYNOPSIS
    Installs the LiwaLink agent (frpc) as a Windows service.

.DESCRIPTION
    Downloads frpc and WinSW (the service wrapper), writes the agent config from
    frpc.toml.template, and registers the "LiwaLink Agent" service. The service
    starts with Windows and restarts if it fails. Re-running upgrades in place.

    Run from an elevated PowerShell. If scripts are blocked, use:
        powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 ...

.EXAMPLE
    .\install-agent.ps1 -RestaurantId rest-1234 -Token <token> -Server link.example.com -LocalPort 5000

.EXAMPLE
    .\install-agent.ps1 -Uninstall
#>
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [ValidatePattern('^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')]
    [string] $RestaurantId,

    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string] $Token,

    # Relay domain, e.g. link.example.com
    [Parameter(Mandatory, ParameterSetName = 'Install')]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string] $Server,

    [Parameter(ParameterSetName = 'Install')]
    [int] $ServerPort = 7000,

    # Where the restaurant API listens on the local network.
    [Parameter(ParameterSetName = 'Install')]
    [ValidatePattern('^[A-Za-z0-9.:-]+$')]
    [string] $LocalHost = '127.0.0.1',

    [Parameter(ParameterSetName = 'Install')]
    [int] $LocalPort = 5000,

    # Relay CA certificate. Default: download https://<Server>/ca.crt
    [Parameter(ParameterSetName = 'Install')]
    [string] $CaCertFile,

    [Parameter(Mandatory, ParameterSetName = 'Uninstall')]
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the progress bar makes downloads very slow on PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$FrpVersion   = '0.71.1'
$WinSWVersion = '2.12.0'
$WinSWSha256  = 'b5066b7bbdfba1293e5d15cda3caaea88fbeab35bd5b38c41c913d492aadfc4f'
$ServiceId    = 'LiwaLinkAgent'
$InstallDir   = Join-Path $env:ProgramFiles 'LiwaLink\Agent'
$LogDir       = Join-Path $env:ProgramData 'LiwaLink\logs'
$ServiceExe   = Join-Path $InstallDir "$ServiceId.exe"
$Utf8NoBom    = New-Object System.Text.UTF8Encoding $false

function Assert-Sha256([string] $Path, [string] $Expected) {
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    if ($actual -ne $Expected) {
        throw "Checksum mismatch for $(Split-Path $Path -Leaf): expected $Expected, got $actual"
    }
}

function Remove-AgentService {
    if (-not (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue)) { return }
    Stop-Service -Name $ServiceId -Force -ErrorAction SilentlyContinue
    if (Test-Path $ServiceExe) { & $ServiceExe uninstall | Out-Null } else { sc.exe delete $ServiceId | Out-Null }
    # Windows can keep a deleted service around for a moment.
    for ($i = 0; $i -lt 20 -and (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 500
    }
}

if ($Uninstall) {
    Remove-AgentService
    if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }
    Write-Host "LiwaLink agent removed. Logs are kept in $LogDir"
    return
}

$RestaurantId = $RestaurantId.ToLowerInvariant()  # ValidatePattern ignores case
$template = Join-Path $PSScriptRoot 'frpc.toml.template'
if (-not (Test-Path $template)) { throw 'frpc.toml.template must be next to this script' }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('liwalink-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host "==> Downloading frpc $FrpVersion ($arch)"
    $zip = "frp_${FrpVersion}_windows_$arch.zip"
    $base = "https://github.com/fatedier/frp/releases/download/v$FrpVersion"
    Invoke-WebRequest -Uri "$base/$zip" -OutFile "$tmp\$zip" -UseBasicParsing
    Invoke-WebRequest -Uri "$base/frp_sha256_checksums.txt" -OutFile "$tmp\sums.txt" -UseBasicParsing
    $line = Select-String -Path "$tmp\sums.txt" -Pattern (' ' + [regex]::Escape($zip) + '$') | Select-Object -First 1
    if (-not $line) { throw "No checksum published for $zip" }
    Assert-Sha256 "$tmp\$zip" ($line.Line -split '\s+')[0]
    Expand-Archive -Path "$tmp\$zip" -DestinationPath $tmp

    Write-Host "==> Downloading WinSW $WinSWVersion (service wrapper)"
    Invoke-WebRequest -Uri "https://github.com/winsw/winsw/releases/download/v$WinSWVersion/WinSW.NET461.exe" -OutFile "$tmp\winsw.exe" -UseBasicParsing
    Assert-Sha256 "$tmp\winsw.exe" $WinSWSha256

    Write-Host '==> Installing'
    Remove-AgentService
    New-Item -ItemType Directory -Force -Path $InstallDir, $LogDir | Out-Null
    Copy-Item -Path "$tmp\frp_${FrpVersion}_windows_$arch\frpc.exe" -Destination $InstallDir -Force
    Copy-Item -Path "$tmp\winsw.exe" -Destination $ServiceExe -Force

    $caFile = Join-Path $InstallDir 'ca.crt'
    if ($CaCertFile) {
        Copy-Item -Path $CaCertFile -Destination $caFile -Force
    } else {
        Invoke-WebRequest -Uri "https://$Server/ca.crt" -OutFile $caFile -UseBasicParsing
    }

    $values = [ordered]@{
        '__SERVER_PORT__'   = "$ServerPort"
        '__SERVER__'        = $Server
        '__RESTAURANT_ID__' = $RestaurantId
        '__TOKEN__'         = $Token
        '__CA_FILE__'       = $caFile
        '__LOCAL_HOST__'    = $LocalHost
        '__LOCAL_PORT__'    = "$LocalPort"
    }
    $config = Get-Content -Path $template -Raw -Encoding UTF8
    foreach ($key in $values.Keys) { $config = $config.Replace($key, $values[$key]) }
    $configFile = Join-Path $InstallDir 'frpc.toml'
    [IO.File]::WriteAllText($configFile, $config, $Utf8NoBom)
    # The token is a secret: only SYSTEM (which runs the service) and Administrators may read it.
    icacls.exe $configFile /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict access to frpc.toml' }

    $frpc = Join-Path $InstallDir 'frpc.exe'
    if (-not (Test-Path $frpc)) {
        throw 'frpc.exe disappeared after copying. Antivirus (often Windows Defender) may have quarantined it; see the README.'
    }
    & $frpc verify -c $configFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'frpc rejected the generated config' }

    $serviceXml = @"
<service>
  <id>$ServiceId</id>
  <name>LiwaLink Agent</name>
  <description>Tunnel from this restaurant to the LiwaLink relay ($Server) so remote apps can reach the local API.</description>
  <executable>%BASE%\frpc.exe</executable>
  <arguments>-c "%BASE%\frpc.toml"</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$LogDir</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
</service>
"@
    [IO.File]::WriteAllText((Join-Path $InstallDir "$ServiceId.xml"), $serviceXml, $Utf8NoBom)

    # Start from fresh logs so the check below only sees this run.
    Remove-Item -Path (Join-Path $LogDir "$ServiceId.*") -ErrorAction SilentlyContinue
    & $ServiceExe install
    if ($LASTEXITCODE -ne 0) { throw 'Registering the service failed' }
    Start-Service -Name $ServiceId

    Write-Host '==> Waiting for the tunnel'
    $outLog = Join-Path $LogDir "$ServiceId.out.log"
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        if ((Test-Path $outLog) -and (Select-String -Path $outLog -Pattern 'start proxy success' -SimpleMatch -Quiet)) {
            Write-Host "Connected. Remote apps can now use https://$RestaurantId.$Server"
            return
        }
    }
    Write-Warning "The service is installed but has not connected yet. Last lines of ${outLog}:"
    if (Test-Path $outLog) { Get-Content -Path $outLog -Tail 20 | Write-Host }
    exit 1
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
