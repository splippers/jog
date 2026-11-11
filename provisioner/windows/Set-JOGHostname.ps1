#Requires -Version 5.1
<#
.SYNOPSIS
    Stage: assign a deterministic computer name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$LogFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

$pattern = [string](Get-JOGProperty $Config 'DeviceNamePattern' 'LT-{Site}-{Serial}')
$site = [string](Get-JOGProperty $Config 'Site' 'SITE01')
$info = Get-JOGModelInfo

# Fall back to the current name when firmware does not provide a usable serial number.
$serial = $info.Serial
if ([string]::IsNullOrWhiteSpace($serial) -or $serial -match '^(To be filled by O\.E\.M\.|Default string|None|0)$') {
    $serial = $env:COMPUTERNAME
}
$serialSlug = ConvertTo-JOGSlug $serial
$modelSlug = ConvertTo-JOGSlug $info.Model

# Substitute the configured template values, sanitize the result, and enforce Windows' 15-character limit.
$name = $pattern
$name = $name.Replace('{Site}', $site)
$name = $name.Replace('{Serial}', $serialSlug)
$name = $name.Replace('{Model}', $modelSlug)
$name = $name -replace '[^A-Za-z0-9-]', '-'
$name = $name.Trim('-')

if ($name.Length -gt 15) {
    $name = $name.Substring(0, 15).TrimEnd('-')
}
if ([string]::IsNullOrWhiteSpace($name)) {
    Write-JOGLog "Computed computer name is empty (pattern '$pattern', serial '$serial')." -Level ERROR -LogFile $LogFile
    return (New-JOGResult $false $false 'Empty computer name')
}

# Avoid an unnecessary reboot if the deterministic name is already assigned.
if ($env:COMPUTERNAME -eq $name) {
    Write-JOGLog "Computer name already $name; no rename needed." -LogFile $LogFile
    return (New-JOGResult $true $false "Already named $name")
}

# Rename only after validation; the orchestrator handles the required reboot and resume.
try {
    Rename-Computer -NewName $name -Force -ErrorAction Stop
    Write-JOGLog "Renamed computer to $name (reboot required)." -LogFile $LogFile
    return (New-JOGResult $true $true "Renamed to $name")
} catch {
    Write-JOGLog "Rename to $name failed: $($_.Exception.Message)" -Level ERROR -LogFile $LogFile
    return (New-JOGResult $false $false "Rename failed: $($_.Exception.Message)")
}
