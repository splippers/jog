#Requires -Version 5.1
<#
.SYNOPSIS
    Upload a vendor driver pack to the JOG Samba driver share from a Windows workstation.

.EXAMPLE
    .\Sync-JOGDrivers.ps1 -Source D:\Drivers\Latitude-3440 -Model Latitude-3440

.EXAMPLE
    .\Sync-JOGDrivers.ps1 -Source \\fileserver\packs\3440 -Model Latitude-3440 -Destination \\10.99.0.1\Drivers -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Model,
    [string]$Destination = '\\10.99.0.1\Drivers',
    [string]$User = 'driveradmin',
    [securestring]$Password,
    [switch]$Mirror
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

# Validate the source and destination folder name before requesting credentials.
if (-not (Test-Path $Source)) {
    throw "Source not found: $Source"
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    throw "Model folder name is required (e.g. Latitude-3440)."
}
if (-not $Password) {
    $Password = Read-Host -AsSecureString "Password for $User"
}

# Convert the secure prompt value only for the duration needed by the SMB mapping helper.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

# Create a timestamped log and describe whether this run adds files or mirrors the source.
$logDir = Join-Path $env:ProgramData 'JOG\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ('driver-sync-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:JOGLogFile = $log

$target = Join-Path $Destination $Model
Write-JOGLog "Source      : $Source"
Write-JOGLog "Destination : $target"
Write-JOGLog "Account     : $User"
Write-JOGLog "Mode        : $(if ($Mirror) { '/MIR' } else { 'add/update' })"

$mapped = New-JOGSmbMapping -RemotePath $Destination -UserName $User -Password $plain
# Stop before copying if authentication to the upload share fails.
if (-not $mapped) {
    Write-JOGLog "Could not map $Destination as $User." -Level ERROR
    exit 1
}

try {
    # Robocopy's /MIR removes destination files absent from the source; -WhatIf uses list-only mode.
    $rcArgs = @($Source, $target, '/R:2', '/W:2', '/NP', '/NFL', '/NDL', "/LOG:$log")
    if ($Mirror) { $rcArgs += '/MIR' }
    if ($WhatIfPreference) { $rcArgs += '/L' }

    if ($PSCmdlet.ShouldProcess($target, 'robocopy driver pack')) {
        Write-JOGLog "Running robocopy"
        $r = Invoke-JOGProcess -FilePath 'robocopy.exe' -ArgumentList $rcArgs
        if ($r.ExitCode -ge 8) {
            Write-JOGLog "robocopy failed (exit $($r.ExitCode)); see $log" -Level ERROR
            exit 1
        }
        Write-JOGLog "robocopy exit $($r.ExitCode) (0-7 = success)"
    }

    # Verify the resulting payload size and remind the operator to test client read access.
    $files = @(Get-ChildItem -Path $target -Recurse -File -ErrorAction SilentlyContinue)
    Write-JOGLog "Target now contains $($files.Count) file(s), $([math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1)) MB"
    Write-JOGLog "Verify read-only access as the 'drivers' account before deploying."
}
finally {
    # Do not leave an authenticated SMB session behind after the upload attempt.
    Remove-JOGSmbMapping -RemotePath $Destination
}

Write-JOGLog "Done. Log: $log"
