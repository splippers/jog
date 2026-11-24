#Requires -Version 5.1
<#
.SYNOPSIS
    Finish Brume provisioning on a device that was imaged on the air-gapped
    network.

.DESCRIPTION
    Run this on the corporate network after the device has completed imaging
    and driver installation. It verifies that Corporate is reachable, prompts
    for a delegated domain-join account, switches the config to Connected, and
    resumes the provisioner at the domain-join stage. The provisioner then
    performs domain join, Entra hybrid join, AD group membership, BitLocker,
    and recovery-password escrow, restarting as needed.

.PARAMETER ConfigPath
    Rendered mist-provisioning.json. Default is beside this script.

.PARAMETER Credential
    Optional delegated domain-join credential. If omitted, Get-Credential
    prompts. The password is written only to the ACL-protected config for the
    duration of the join and is removed by the provisioner's CLEANUP stage.

.PARAMETER SkipConnectivityCheck
    Lab only. Do not verify DNS/DC reachability before changing the config.

.PARAMETER NoReboot
    Pass through to the provisioner for inspection.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'mist-provisioning.json'),
    [PSCredential]$Credential,
    [switch]$SkipConnectivityCheck,
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

# A double-clicked shortcut starts unelevated. Relaunch through UAC once so the
# domain join and BitLocker cmdlets can run.
if (-not (Test-JOGAdministrator)) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`""
    if ($SkipConnectivityCheck) { $argLine += ' -SkipConnectivityCheck' }
    if ($NoReboot) { $argLine += ' -NoReboot' }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -Verb RunAs
    exit 0
}

if (-not (Test-Path $ConfigPath)) {
    Write-Host "Config not found: $ConfigPath" -ForegroundColor Red
    exit 1
}

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$mode = [string](Get-JOGProperty $config 'ProvisioningMode' 'AirGapped')
$domainJoin = Get-JOGProperty $config 'DomainJoin' $null
$hybridBlock = Get-JOGProperty $config 'HybridJoin' $null
$domain = [string](Get-JOGProperty $config 'Domain' '')
$joinMode = [string](Get-JOGProperty $domainJoin 'Mode' 'Credential')
$hybrid = [bool](Get-JOGProperty $hybridBlock 'Enabled' $true)
if ([string]::IsNullOrWhiteSpace($domain)) {
    Write-Host 'Domain is empty in the provisioning config.' -ForegroundColor Red
    exit 1
}
if ($joinMode -notin @('Offline', 'Credential')) {
    Write-Host "DomainJoin.Mode must be Offline or Credential, not '$joinMode'." -ForegroundColor Red
    exit 1
}

Write-Host 'Brume corporate enrollment resume' -ForegroundColor Cyan
Write-Host "  device : $env:COMPUTERNAME"
Write-Host "  domain : $domain"
Write-Host "  mode   : $mode"

if ($mode -eq 'Connected') {
    Write-Host 'Config is already Connected; resuming the provisioner.' -ForegroundColor Yellow
}

if (-not $SkipConnectivityCheck) {
    Write-Host 'Checking corporate reachability...'
    try {
        [void][System.Net.Dns]::GetHostAddresses($domain)
    } catch {
        Write-Host "Cannot resolve $domain. Connect to the corporate network or VPN and retry." -ForegroundColor Red
        exit 2
    }

    $dc = & nltest.exe "/dsgetdc:$domain" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "No domain controller responded for $domain." -ForegroundColor Red
        Write-Host ($dc | Out-String)
        Write-Host 'Connect to the corporate network or VPN and retry.' -ForegroundColor Red
        exit 2
    }
    Write-Host '  domain controller reachable' -ForegroundColor Green

    if ($hybrid) {
        foreach ($endpoint in @('login.microsoftonline.com', 'enterpriseregistration.windows.net')) {
            $probe = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
            if ($probe.TcpTestSucceeded) {
                Write-Host "  $endpoint reachable" -ForegroundColor Green
            } else {
                Write-Host "  $endpoint is not reachable; Entra hybrid join may fail." -ForegroundColor Yellow
            }
        }
    }
}

$joinUser = ''
$plain = ''
if ($joinMode -eq 'Credential') {
    if (-not $Credential) {
        $hint = [string](Get-JOGProperty $domainJoin 'User' '')
        if ([string]::IsNullOrWhiteSpace($hint)) { $hint = "$domain\svc-mist-join" }
        $Credential = Get-Credential -UserName $hint -Message "Delegated domain-join account for $domain"
        if (-not $Credential) { exit 3 }
    }

    $joinUser = $Credential.UserName
    if ($joinUser -notmatch '\\' -and $joinUser -notmatch '@') { $joinUser = "$domain\$joinUser" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
} else {
    Write-Host 'Offline join configured; no domain password is needed.' -ForegroundColor Cyan
}

# Switch the config in place so the AtStartup resume task, which uses the
# default config path, continues with Connected mode after any restart.
$config.ProvisioningMode = 'Connected'
if ($joinMode -eq 'Credential' -and $config.PSObject.Properties['DomainJoin']) {
    $config.DomainJoin.User = $joinUser
    $config.DomainJoin.Password = $plain
}
$config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigPath -Encoding UTF8
Set-JOGFileAcl -Path $ConfigPath

Write-Host 'Resuming provisioning: domain join, hybrid join, groups, BitLocker, escrow.' -ForegroundColor Cyan
$arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $PSScriptRoot 'Start-JOGProvisioning.ps1'),
    '-ConfigPath', $ConfigPath, '-Resume'
)
if ($NoReboot) { $arguments += '-NoReboot' }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Host "Provisioning resume failed with exit $rc. The join password remains in the ACL-protected config for retry." -ForegroundColor Red
}
exit $rc
