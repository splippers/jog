#Requires -Version 5.1
<#
.SYNOPSIS
    Stages: domain join, Entra hybrid-join wait, AD group membership.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$LogFile,
    [Parameter(Mandatory)][ValidateSet('Join','Hybrid','Groups')][string]$Stage
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

$join = Get-JOGProperty $Config 'DomainJoin' $null
$domain = [string](Get-JOGProperty $Config 'Domain' '')
$ou = [string](Get-JOGProperty $join 'OUPath' '')
$mode = [string](Get-JOGProperty $join 'Mode' 'Offline')

# Apply the configured offline djoin blob or delegated credential domain join.
function Invoke-JOGJoinStage {
    if (Test-JOGDomainJoined) {
        Write-JOGLog "Computer is already domain joined." -LogFile $LogFile
        return (New-JOGResult $true $false 'Already domain joined')
    }

    if ([string]::IsNullOrWhiteSpace($domain)) {
        return (New-JOGResult $false $false 'Domain is empty in the config')
    }

    if ($mode -eq 'Offline') {
        $blob = [string](Get-JOGProperty $join 'BlobPath' (Join-Path $PSScriptRoot 'domainjoin.blob'))
        if (-not (Test-Path $blob)) {
            return (New-JOGResult $false $false "Offline join blob not found: $blob")
        }
        Write-JOGLog "Offline domain join from $blob" -LogFile $LogFile
        $r = Invoke-JOGProcess -FilePath 'djoin.exe' -ArgumentList @(
            '/requestODJ', '/loadfile', $blob, '/windowspath', $env:SystemRoot, '/localos'
        )
        if (-not $r.Success) {
            return (New-JOGResult $false $false "djoin failed (exit $($r.ExitCode)): $($r.Output)")
        }
        return (New-JOGResult $true $true 'Offline join applied; reboot required')
    }

    $cred = Get-JOGDomainCredential $Config
    if (-not $cred) {
        return (New-JOGResult $false $false 'Credential join selected but DomainJoin.User/Password are empty')
    }

    $params = @{
        DomainName = $domain
        Credential = $cred
        Force      = $true
        Options    = 'JoinWithNewName', 'AccountCreate'
    }
    if (-not [string]::IsNullOrWhiteSpace($ou)) { $params['OUPath'] = $ou }

    try {
        Write-JOGLog "Credential domain join to $domain (OU: $ou)" -LogFile $LogFile
        Add-Computer @params -ErrorAction Stop
        return (New-JOGResult $true $true 'Domain join applied; reboot required')
    } catch {
        return (New-JOGResult $false $false "Add-Computer failed: $($_.Exception.Message)")
    }
}

# Wait for Entra hybrid join to complete, periodically triggering the Windows join task.
function Invoke-JOGHybridStage {
    $hybrid = Get-JOGProperty $Config 'HybridJoin' $null
    $enabled = [bool](Get-JOGProperty $hybrid 'Enabled' $false)
    if (-not $enabled) {
        Write-JOGLog "Hybrid join disabled; skipping." -LogFile $LogFile
        return (New-JOGResult $true $false 'Hybrid join disabled')
    }

    $timeout = [int](Get-JOGProperty $hybrid 'TimeoutMinutes' 30)
    if ($timeout -lt 1) { $timeout = 30 }
    $deadline = (Get-Date).AddMinutes($timeout)
    $last = $null

    while ((Get-Date) -lt $deadline) {
        $status = Get-JOGDsRegStatus
        $last = $status
        Write-JOGLog ("dsregcmd: AzureAdJoined={0} DomainJoined={1} DeviceAuthStatus={2}" -f `
            $status.AzureAdJoined, $status.DomainJoined, $status.DeviceAuthStatus) -LogFile $LogFile

        if ($status.AzureAdJoined -and $status.DomainJoined) {
            return (New-JOGResult $true $false 'Hybrid join complete')
        }

        try {
            Start-ScheduledTask -TaskPath '\Microsoft\Windows\Workplace Join\' -TaskName 'Automatic-Device-Join' -ErrorAction SilentlyContinue
        } catch { }
        try { & dsregcmd.exe /join 2>&1 | Out-Null } catch { }

        Start-Sleep -Seconds 30
    }

    $detail = if ($last) {
        "AzureAdJoined=$($last.AzureAdJoined) DomainJoined=$($last.DomainJoined) DeviceAuthStatus=$($last.DeviceAuthStatus)"
    } else { 'no dsregcmd output' }
    return (New-JOGResult $false $false "Hybrid join not complete after $timeout minutes ($detail)")
}

# Query domain group membership and report whether this computer account is listed.
function Test-JOGGroupMembership {
    param([string]$Group)
    $r = Invoke-JOGProcess -FilePath 'net.exe' -ArgumentList @('group', $Group, '/domain')
    return ($r.Success -and ($r.Output -match [regex]::Escape($env:COMPUTERNAME)))
}

# Add the computer to each configured group when allowed, then report any missing membership.
function Invoke-JOGGroupsStage {
    $groups = @(Get-JOGProperty $Config 'Groups' @())
    $groups = @($groups | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($groups.Count -eq 0) {
        Write-JOGLog "No AD groups configured; skipping." -LogFile $LogFile
        return (New-JOGResult $true $false 'No groups configured')
    }

    $groupsMode = [string](Get-JOGProperty $Config 'GroupsMode' 'Device')
    $cred = Get-JOGDomainCredential $Config
    $missing = @()

    foreach ($group in $groups) {
        if (Test-JOGGroupMembership -Group $group) {
            Write-JOGLog "Already a member of $group" -LogFile $LogFile
            continue
        }

        if ($groupsMode -eq 'Device' -and $cred) {
            $cmd = "net group `"$group`" `"$env:COMPUTERNAME`$`" /add /domain"
            Write-JOGLog "Adding $env:COMPUTERNAME`$ to $group as $($cred.UserName)" -LogFile $LogFile
            try {
                $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
                    -ArgumentList "/c $cmd" -Credential $cred -Wait -PassThru -WindowStyle Hidden
                if ($p.ExitCode -ne 0) {
                    Write-JOGLog "net group exited $($p.ExitCode) for $group" -Level WARN -LogFile $LogFile
                }
            } catch {
                Write-JOGLog "Could not run net group for $group : $($_.Exception.Message)" -Level WARN -LogFile $LogFile
            }
            if (-not (Test-JOGGroupMembership -Group $group)) { $missing += $group }
        } else {
            $missing += $group
        }
    }

    if ($missing.Count -gt 0) {
        $msg = "Not a member of: $($missing -join ', '). For offline join, run Add-JOGComputerGroups.ps1 from a management host."
        Write-JOGLog $msg -Level ERROR -LogFile $LogFile
        return (New-JOGResult $false $false $msg)
    }

    return (New-JOGResult $true $false "Member of: $($groups -join ', ')")
}

switch ($Stage) {
    'Join'   { Invoke-JOGJoinStage }
    'Hybrid' { Invoke-JOGHybridStage }
    'Groups' { Invoke-JOGGroupsStage }
}
