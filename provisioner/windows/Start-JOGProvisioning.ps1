#Requires -Version 5.1
<#
.SYNOPSIS
    JOG corporate provisioning orchestrator.

.DESCRIPTION
    Runs as SYSTEM from SetupComplete.cmd and from the JOGProvisioning scheduled task.
    Stages are idempotent and resumable. State lives in C:\ProgramData\JOG\Provisioning.json.

.PARAMETER ConfigPath
    Path to the rendered jog-provisioning.json.

.PARAMETER Resume
    Accepted for the scheduled task / SetupComplete call. The orchestrator always resumes from state.

.PARAMETER Force
    Re-run completed stages and retry a FAILED state.

.PARAMETER NoReboot
    Do not restart the computer; useful for lab inspection. The state will remain at the stage boundary.

.PARAMETER NoResumeTask
    Do not register the JOGProvisioning startup task. Lab only.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'jog-provisioning.json'),
    [switch]$Resume,
    [switch]$Force,
    [switch]$NoReboot,
    [switch]$NoResumeTask
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

$script:JOGRoot   = $PSScriptRoot
$script:JOGLogDir = Join-Path $script:JOGRoot 'logs'
$script:JOGLogFile = Join-Path $script:JOGLogDir ('provisioning-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$statePath = Join-Path $script:JOGRoot 'Provisioning.json'

New-Item -ItemType Directory -Force -Path $script:JOGLogDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $script:JOGRoot 'Secrets') | Out-Null

Write-JOGLog "JOG provisioner starting"
Write-JOGLog "  config : $ConfigPath"
Write-JOGLog "  state  : $statePath"
Write-JOGLog "  log    : $script:JOGLogFile"
Write-JOGLog "  resume : $Resume  force : $Force  no-reboot : $NoReboot"

if (-not (Test-JOGAdministrator)) {
    Write-JOGLog "Must run as SYSTEM or an administrator." -Level ERROR
    exit 1
}
if (-not (Test-Path $ConfigPath)) {
    Write-JOGLog "Config not found: $ConfigPath" -Level ERROR
    exit 1
}

try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
} catch {
    Write-JOGLog "Config is not valid JSON: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# Load the saved state machine data, or create a safe IMAGE_APPLIED starting state.
function Read-JOGState {
    $default = @{
        Version      = 1
        State        = 'IMAGE_APPLIED'
        ComputerName = $env:COMPUTERNAME
        Updated      = (Get-Date).ToString('o')
        Attempts     = 0
        LastError    = ''
        Stages       = @{}
    }
    if (-not (Test-Path $statePath)) { return $default }
    try {
        $raw = Get-Content -Path $statePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $state = @{
            Version      = Get-JOGProperty $raw 'Version' 1
            State        = Get-JOGProperty $raw 'State' 'IMAGE_APPLIED'
            ComputerName = Get-JOGProperty $raw 'ComputerName' $env:COMPUTERNAME
            Updated      = Get-JOGProperty $raw 'Updated' (Get-Date).ToString('o')
            Attempts     = [int](Get-JOGProperty $raw 'Attempts' 0)
            LastError    = Get-JOGProperty $raw 'LastError' ''
            Stages       = @{}
        }
        $rawStages = Get-JOGProperty $raw 'Stages' $null
        if ($rawStages) {
            foreach ($p in $rawStages.PSObject.Properties) { $state.Stages[$p.Name] = [string]$p.Value }
        }
        return $state
    } catch {
        Write-JOGLog "State file unreadable; starting from IMAGE_APPLIED: $($_.Exception.Message)" -Level WARN
        return $default
    }
}

# Persist the current stage, attempt count, computer name, and timestamp to disk.
function Save-JOGState {
    param([hashtable]$State)
    $State.Updated = (Get-Date).ToString('o')
    $State.ComputerName = $env:COMPUTERNAME
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -Path $statePath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-JOGLog "Could not save state: $($_.Exception.Message)" -Level ERROR
    }
}

# Register the SYSTEM startup task that resumes provisioning after required reboots.
function Register-JOGResumeTask {
    $action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resume"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName 'JOGProvisioning' `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

# Remove the startup resume task once all provisioning stages have completed.
function Unregister-JOGResumeTask {
    try { Unregister-ScheduledTask -TaskName 'JOGProvisioning' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
}

# Stop at the current stage for lab runs, or register resume and reboot the device.
function Restart-JOGComputer {
    param([string]$Reason)
    if ($NoReboot) {
        Write-JOGLog "Reboot required ($Reason) but -NoReboot is set; stopping at the stage boundary." -Level WARN
        exit 0
    }
    if (-not $NoResumeTask) {
        try { Register-JOGResumeTask } catch {
            Write-JOGLog "Cannot register the resume task; refusing to reboot: $($_.Exception.Message)" -Level ERROR
            exit 1
        }
    }
    Write-JOGLog "Restarting computer: $Reason"
    Restart-Computer -Force
    exit 0
}

# Run one stage script with its inputs and normalize missing results or thrown errors.
function Invoke-JOGStageScript {
    param([string]$Script, [hashtable]$Parameters)
    $path = Join-Path $script:JOGRoot $Script
    if (-not (Test-Path $path)) { return New-JOGResult $false $false "Missing stage script: $Script" }
    try {
        $result = & $path @Parameters
        if ($null -eq $result) { return New-JOGResult $false $false "$Script returned no result" }
        return $result
    } catch {
        return New-JOGResult $false $false "$Script threw: $($_.Exception.Message)"
    }
}

# Load the checkpoint and ensure every known stage has an explicit initial status.

$state = Read-JOGState
$stageNames = @('INITIALISE','DRIVERS','HOSTNAME','DOMAIN_JOIN','HYBRID_JOIN','GROUPS','BITLOCKER','ESCROW','CLEANUP')
foreach ($name in $stageNames) {
    if (-not $state.Stages.ContainsKey($name)) { $state.Stages[$name] = 'pending' }
}

if ($state.State -eq 'COMPLETE' -and -not $Force) {
    Write-JOGLog "Provisioning already COMPLETE. Use -Force to re-run." -Level INFO
    exit 0
}
if ($state.State -eq 'FAILED' -and -not $Force) {
    Write-JOGLog "Provisioning is FAILED (attempts=$($state.Attempts)). Use -Force after fixing the cause." -Level ERROR
    exit 1
}

$maxAttempts = [int](Get-JOGProperty $config 'MaxAttempts' 5)
$rebootBetween = [bool](Get-JOGProperty $config 'RebootBetweenStages' $true)
$completedState = @{
    DRIVERS      = 'DRIVERS_INSTALLED'
    HOSTNAME     = 'HOSTNAME_ASSIGNED'
    DOMAIN_JOIN  = 'DIRECTORY_JOINED'
    HYBRID_JOIN  = 'HYBRID_JOINED'
    GROUPS       = 'GROUPS_ASSIGNED'
    BITLOCKER    = 'BITLOCKER_CONFIGURED'
    ESCROW       = 'ESCROW_VERIFIED'
}

# Secure the working files and register the resume task before modifying the device.

if ($state.Stages['INITIALISE'] -ne 'done' -or $Force) {
    Write-JOGLog "Stage INITIALISE starting"
    Set-JOGFileAcl -Path $script:JOGRoot -Directory
    Set-JOGFileAcl -Path $ConfigPath
    Set-JOGFileAcl -Path (Join-Path $script:JOGRoot 'Secrets') -Directory
    Set-JOGFileAcl -Path $statePath
    if (-not $NoResumeTask) {
        try {
            Register-JOGResumeTask
            Write-JOGLog "Registered scheduled task JOGProvisioning (AtStartup, SYSTEM)"
        } catch {
            Write-JOGLog "Could not register JOGProvisioning task: $($_.Exception.Message)" -Level ERROR
            exit 1
        }
    }
    $state.Stages['INITIALISE'] = 'done'
    $state.State = 'IMAGE_APPLIED'
    Save-JOGState $state
    Write-JOGLog "Stage INITIALISE done"
}

# Map each state-machine stage to the script and parameters that implement it.

$stageActions = [ordered]@{
    DRIVERS = {
        Invoke-JOGStageScript 'Install-JOGDrivers.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
        }
    }
    HOSTNAME = {
        Invoke-JOGStageScript 'Set-JOGHostname.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
        }
    }
    DOMAIN_JOIN = {
        Invoke-JOGStageScript 'Join-JOGDomain.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
            Stage   = 'Join'
        }
    }
    HYBRID_JOIN = {
        Invoke-JOGStageScript 'Join-JOGDomain.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
            Stage   = 'Hybrid'
        }
    }
    GROUPS = {
        Invoke-JOGStageScript 'Join-JOGDomain.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
            Stage   = 'Groups'
        }
    }
    BITLOCKER = {
        Invoke-JOGStageScript 'Enable-JOGBitLocker.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
            Stage   = 'Enable'
        }
    }
    ESCROW = {
        Invoke-JOGStageScript 'Enable-JOGBitLocker.ps1' @{
            Config  = $config
            LogFile = $script:JOGLogFile
            Stage   = 'Verify'
        }
    }
}

# Skip completed work, save stage boundaries, and stop with a resumable state on failure.
foreach ($stage in $stageActions.Keys) {
    if ($state.Stages[$stage] -eq 'done' -and -not $Force) {
        Write-JOGLog "Stage $stage already done; skipping"
        continue
    }

    $state.State = "${stage}_RUNNING"
    Save-JOGState $state
    Write-JOGLog "Stage $stage starting"

    $result = & $stageActions[$stage]
    if ($null -eq $result) {
        $result = New-JOGResult $false $false "Stage $stage returned no result"
    }

    if (-not $result.Success) {
        $state.Stages[$stage] = 'failed'
        $state.State = "${stage}_PENDING"
        $state.LastError = [string]$result.Message
        $state.Attempts = [int]$state.Attempts + 1
        Save-JOGState $state
        Write-JOGLog "Stage $stage failed: $($result.Message)" -Level ERROR
        if ($state.Attempts -ge $maxAttempts) {
            $state.State = 'FAILED'
            Save-JOGState $state
            Write-JOGLog "Maximum attempts ($maxAttempts) reached; state is FAILED." -Level ERROR
        }
        exit 1
    }

    $state.Stages[$stage] = 'done'
    $state.LastError = ''
    $state.Attempts = 0
    if ($completedState.ContainsKey($stage)) { $state.State = $completedState[$stage] }
    Save-JOGState $state
    Write-JOGLog "Stage $stage done: $($result.Message)"

    if ($result.RebootRequired -and $rebootBetween) {
        Restart-JOGComputer -Reason "stage $stage requested a reboot"
    }
}

# Remove reusable credentials from config, mark completion, and retire temporary state.

if ($state.Stages['CLEANUP'] -ne 'done' -or $Force) {
    Write-JOGLog "Stage CLEANUP starting"

    # Remove secrets from the rendered config before deleting it.
    try {
        if ($config.PSObject.Properties['DriverShare']) { $config.DriverShare.ReadPassword = '' }
        if ($config.PSObject.Properties['DomainJoin']) { $config.DomainJoin.Password = '' }
        $config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigPath -Encoding UTF8
        Set-JOGFileAcl -Path $ConfigPath
    } catch {
        Write-JOGLog "Could not sanitise the config: $($_.Exception.Message)" -Level WARN
    }

    $state.Stages['CLEANUP'] = 'done'
    $state.State = 'COMPLETE'
    Save-JOGState $state

    if (-not $NoResumeTask) { Unregister-JOGResumeTask }

    if ([bool](Get-JOGProperty $config 'DeleteConfigOnComplete' $true)) {
        Remove-Item -Path $ConfigPath -Force -ErrorAction SilentlyContinue
        Write-JOGLog "Removed the rendered config (secrets gone; state and logs retained)."
    }

    $pinFile = Join-Path $script:JOGRoot 'BitLockerPin.txt'
    if (Test-Path $pinFile) {
        Write-JOGLog "A one-time BitLocker PIN file remains at $pinFile. Retrieve it and delete it." -Level WARN
    }

    Write-JOGLog "Stage CLEANUP done; provisioning is COMPLETE."

    if ([bool](Get-JOGProperty $config 'ShutdownOnComplete' $false)) {
        Write-JOGLog "ShutdownOnComplete is set; shutting down."
        Stop-Computer -Force
    }
}

exit 0
