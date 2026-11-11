#Requires -Version 5.1
<#
.SYNOPSIS
    Stages: enable BitLocker and verify recovery-key escrow.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$LogFile,
    [Parameter(Mandatory)][ValidateSet('Enable','Verify')][string]$Stage
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

$bl = Get-JOGProperty $Config 'BitLocker' $null
if (-not $bl -or -not [bool](Get-JOGProperty $bl 'Enabled' $true)) {
    Write-JOGLog "BitLocker disabled; skipping." -LogFile $LogFile
    return (New-JOGResult $true $false 'BitLocker disabled')
}

$mode = [string](Get-JOGProperty $bl 'Mode' 'TpmOnly')
$escrow = [string](Get-JOGProperty $bl 'Escrow' 'AD')
$pinStorage = [string](Get-JOGProperty $bl 'PinStorage' 'None')
$markerPath = Join-Path $PSScriptRoot 'escrow-verified.json'

# Query BitLocker details for the system volume.
function Get-JOGVolume {
    Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
}

# Find the existing recovery-password protector so it can be escrowed or verified.
function Get-JOGRecoveryProtector {
    param($Volume)
    $Volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
}

# Check TPM readiness using the BitLocker cmdlet, with a WMI fallback for older systems.
function Test-JOGTpmReady {
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        return [bool]$tpm.TpmReady
    } catch {
        try {
            $tpm = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop
            return ([bool]$tpm.IsEnabled_InitialValue -and [bool]$tpm.IsActivated_InitialValue)
        } catch {
            Write-JOGLog "TPM query failed: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
            return $false
        }
    }
}

# Store a configured TPM+PIN value using the selected storage policy.
function Save-JOGPin {
    param([string]$Pin, [string]$Storage)
    switch ($Storage) {
        'LocalDPAPI' {
            $dir = Join-Path $PSScriptRoot 'Secrets'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $secure = ConvertTo-SecureString $Pin -AsPlainText -Force
            $encrypted = ConvertFrom-SecureString $secure
            $path = Join-Path $dir 'BitLockerPin.dpapi'
            Set-Content -Path $path -Value $encrypted -Encoding UTF8
            Set-JOGFileAcl -Path $path
            Write-JOGLog "BitLocker PIN sealed with DPAPI at $path (SYSTEM/Administrators only)." -Level WARN -LogFile $LogFile
        }
        'ADCustomAttribute' {
            if (-not [bool](Get-JOGProperty $bl 'AllowAdPinStorage' $false)) {
                throw "PinStorage=ADCustomAttribute requires AllowAdPinStorage=true. Refusing to write a PIN to AD."
            }
            $attr = [string](Get-JOGProperty $bl 'AdPinAttribute' 'extensionAttribute15')
            $cred = Get-JOGDomainCredential $Config
            if (-not $cred) { throw "ADCustomAttribute requires DomainJoin.User/Password for the write." }
            Import-Module ActiveDirectory -ErrorAction Stop
            $update = @{}
            $update[$attr] = $Pin
            Set-ADComputer -Identity $env:COMPUTERNAME -Add $update -Credential $cred -ErrorAction Stop
            Write-JOGLog "WARNING: wrote the BitLocker PIN to AD attribute $attr on $env:COMPUTERNAME. This is not recommended." -Level WARN -LogFile $LogFile
        }
        default {
            $path = Join-Path $PSScriptRoot 'BitLockerPin.txt'
            Set-Content -Path $path -Value $Pin -Encoding UTF8
            Set-JOGFileAcl -Path $path
            Write-JOGLog "BitLocker PIN written one-time to $path. Retrieve and delete it." -Level WARN -LogFile $LogFile
        }
    }
}

# Enable protection, ensure a recovery protector exists, and back it up to configured directories.
function Invoke-JOGEnableStage {
    $volume = Get-JOGVolume
    if ($volume.ProtectionStatus -ne 'On') {
        if (-not (Test-JOGTpmReady)) {
            return (New-JOGResult $false $false 'TPM is not ready; BitLocker not enabled')
        }

        $params = @{
            MountPoint       = 'C:'
            EncryptionMethod = 'XtsAes256'
            UsedSpaceOnly    = $true
            SkipHardwareTest = $true
        }
        $pin = $null
        if ($mode -eq 'TpmPin') {
            $pin = New-JOGPin -Length ([int](Get-JOGProperty $bl 'PinLength' 6))
            $params['TpmAndPinProtector'] = $true
            $params['Pin'] = (ConvertTo-SecureString $pin -AsPlainText -Force)
            Write-JOGLog "Enabling BitLocker with TPM + PIN ($($pin.Length) digits)." -LogFile $LogFile
        } else {
            $params['TpmProtector'] = $true
            Write-JOGLog "Enabling BitLocker with TPM-only (no pre-boot PIN)." -LogFile $LogFile
        }

        try {
            Enable-BitLocker @params -ErrorAction Stop | Out-Null
        } catch {
            return (New-JOGResult $false $false "Enable-BitLocker failed: $($_.Exception.Message)")
        }

        if ($pin) {
            try { Save-JOGPin -Pin $pin -Storage $pinStorage }
            catch { return (New-JOGResult $false $false "PIN delivery failed: $($_.Exception.Message)") }
        }

        $volume = Get-JOGVolume
    } else {
        Write-JOGLog "BitLocker is already on; ensuring a recovery-password protector exists." -LogFile $LogFile
    }

    $rp = Get-JOGRecoveryProtector -Volume $volume
    if (-not $rp) {
        try {
            $rp = Add-BitLockerKeyProtector -MountPoint 'C:' -RecoveryPasswordProtector -ErrorAction Stop
            Write-JOGLog "Added recovery-password protector $($rp.KeyProtectorId)." -LogFile $LogFile
        } catch {
            return (New-JOGResult $false $false "Could not add a recovery-password protector: $($_.Exception.Message)")
        }
    } else {
        Write-JOGLog "Recovery-password protector: $($rp.KeyProtectorId)" -LogFile $LogFile
    }

    $verified = @()
    if ($escrow -in @('AD', 'Both')) {
        $r = Invoke-JOGProcess -FilePath 'manage-bde.exe' -ArgumentList @(
            '-protectors', '-adbackup', 'C:', '-id', $rp.KeyProtectorId
        )
        if (-not $r.Success) {
            return (New-JOGResult $false $false "AD escrow failed (exit $($r.ExitCode)): $($r.Output)")
        }
        $verified += 'AD'
        Write-JOGLog "Recovery password backed up to AD." -LogFile $LogFile
    }

    if ($escrow -in @('Entra', 'Both')) {
        try {
            BackupToAAD-BitLockerKeyProtector -MountPoint 'C:' -KeyProtectorId $rp.KeyProtectorId -ErrorAction Stop | Out-Null
            $verified += 'Entra'
            Write-JOGLog "Recovery password backed up to Entra ID." -LogFile $LogFile
        } catch {
            return (New-JOGResult $false $false "Entra escrow failed: $($_.Exception.Message)")
        }
    }

    if ($verified.Count -eq 0) {
        return (New-JOGResult $false $false "No escrow target configured (Escrow=$escrow). Refusing to call this verified.")
    }

    $marker = [pscustomobject]@{
        Method        = $escrow
        Verified      = $verified
        KeyProtectorId = $rp.KeyProtectorId
        ComputerName  = $env:COMPUTERNAME
        Time          = (Get-Date).ToString('o')
    }
    $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $markerPath -Encoding UTF8
    Set-JOGFileAcl -Path $markerPath

    return (New-JOGResult $true $false "BitLocker on; escrow: $($verified -join ', ')")
}

# Confirm protection, recovery-key escrow evidence, and completed volume encryption.
function Invoke-JOGVerifyStage {
    $volume = Get-JOGVolume
    if ($volume.ProtectionStatus -ne 'On') {
        return (New-JOGResult $false $false 'BitLocker protection is not On')
    }

    $rp = Get-JOGRecoveryProtector -Volume $volume
    if (-not $rp) {
        return (New-JOGResult $false $false 'No recovery-password protector on C:')
    }

    if (-not (Test-Path $markerPath)) {
        return (New-JOGResult $false $false 'No escrow marker; the backup step did not complete')
    }
    $marker = Get-Content -Path $markerPath -Raw | ConvertFrom-Json
    $markerMethod = [string]$marker.Method

    if ($markerMethod -in @('AD', 'Both')) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $computer = Get-ADComputer -Identity $env:COMPUTERNAME -Properties 'msFVE-RecoveryInformation' -ErrorAction Stop
            if (-not $computer.'msFVE-RecoveryInformation') {
                return (New-JOGResult $false $false "AD has no msFVE-RecoveryInformation for $env:COMPUTERNAME")
            }
            Write-JOGLog "AD contains msFVE-RecoveryInformation for $env:COMPUTERNAME." -LogFile $LogFile
        } catch {
            Write-JOGLog "AD verification skipped (RSAT/read access unavailable): $($_.Exception.Message)" -Level WARN -LogFile $LogFile
        }
    }

    # Wait for the volume to finish encrypting. UsedSpaceOnly is usually quick, but do not lie about it.
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $volume = Get-JOGVolume
        if ($volume.VolumeStatus -eq 'FullyEncrypted' -or $volume.EncryptionPercentage -eq 100) { break }
        Write-JOGLog ("Encryption in progress: {0}% ({1})" -f $volume.EncryptionPercentage, $volume.VolumeStatus) -LogFile $LogFile
        Start-Sleep -Seconds 30
    }
    $volume = Get-JOGVolume
    if (-not ($volume.VolumeStatus -eq 'FullyEncrypted' -or $volume.EncryptionPercentage -eq 100)) {
        return (New-JOGResult $false $false "Encryption did not finish within 30 minutes (status $($volume.VolumeStatus), $($volume.EncryptionPercentage)%)")
    }

    return (New-JOGResult $true $false "BitLocker fully encrypted; escrow marker: $($marker.Method)")
}

switch ($Stage) {
    'Enable' { Invoke-JOGEnableStage }
    'Verify' { Invoke-JOGVerifyStage }
}
