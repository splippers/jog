#Requires -Version 5.1
<#
.SYNOPSIS
    Show the JOG provisioning state, stage table, domain/Entra status, and BitLocker state.
#>
[CmdletBinding()]
param([string]$Root = $PSScriptRoot)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

$statePath = Join-Path $Root 'Provisioning.json'
# Stop early when the orchestrator has not created its checkpoint file.
if (-not (Test-Path $statePath)) {
    Write-Host "No provisioning state at $statePath"
    exit 1
}

# Print the saved state-machine checkpoint and its per-stage results.
$state = Get-Content -Path $statePath -Raw | ConvertFrom-Json
Write-Host ""
Write-Host "JOG provisioning status" -ForegroundColor Cyan
Write-Host "=======================" -ForegroundColor DarkCyan
Write-Host ("Computer : {0}" -f (Get-JOGProperty $state 'ComputerName' $env:COMPUTERNAME))
Write-Host ("State    : {0}" -f (Get-JOGProperty $state 'State' 'unknown'))
Write-Host ("Updated  : {0}" -f (Get-JOGProperty $state 'Updated' ''))
Write-Host ("Attempts : {0}" -f (Get-JOGProperty $state 'Attempts' 0))
$lastError = [string](Get-JOGProperty $state 'LastError' '')
if ($lastError) { Write-Host ("LastError: {0}" -f $lastError) -ForegroundColor Yellow }

Write-Host ""
Write-Host "Stages" -ForegroundColor Cyan
$stages = Get-JOGProperty $state 'Stages' $null
if ($stages) {
    foreach ($p in $stages.PSObject.Properties) {
        $colour = switch ([string]$p.Value) {
            'done'    { 'Green' }
            'failed'  { 'Red' }
            'pending' { 'DarkGray' }
            default   { 'Yellow' }
        }
        Write-Host ("  {0,-14} {1}" -f $p.Name, $p.Value) -ForegroundColor $colour
    }
}

Write-Host ""
Write-Host "Directory" -ForegroundColor Cyan
# Read current directory join status directly from Windows.
$dsreg = Get-JOGDsRegStatus
Write-Host ("  DomainJoined    : {0}" -f $dsreg.DomainJoined)
Write-Host ("  AzureAdJoined   : {0}" -f $dsreg.AzureAdJoined)
Write-Host ("  DeviceAuthStatus: {0}" -f $dsreg.DeviceAuthStatus)

Write-Host ""
Write-Host "BitLocker" -ForegroundColor Cyan
# Query live BitLocker status and locate the recovery protector without exposing its secret.
try {
    $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    Write-Host ("  Protection : {0}" -f $vol.ProtectionStatus)
    Write-Host ("  Status     : {0} ({1}%)" -f $vol.VolumeStatus, $vol.EncryptionPercentage)
    $rp = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    Write-Host ("  Recovery   : {0}" -f $(if ($rp) { $rp.KeyProtectorId } else { 'none' }))
} catch {
    Write-Host "  BitLocker query failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Show the local marker written by the escrow stage, when one exists.
$marker = Join-Path $Root 'escrow-verified.json'
if (Test-Path $marker) {
    Write-Host ""
    Write-Host "Escrow marker" -ForegroundColor Cyan
    Get-Content -Path $marker -Raw
}

Write-Host ""
