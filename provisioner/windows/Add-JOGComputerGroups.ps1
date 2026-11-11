#Requires -Version 5.1
<#
.SYNOPSIS
    Add pre-created computer accounts to AD groups from a management host (offline-join workflow).

.DESCRIPTION
    Offline domain join leaves no reusable domain credential on the device. Run this from a
    domain-joined management host with RSAT after the computer accounts exist (or after the
    devices have joined). It is idempotent.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string[]]$ComputerName,
    [Parameter(Mandatory)][string[]]$Groups,
    [pscredential]$Credential,
    [string]$Server
)

$ErrorActionPreference = 'Stop'
# Use AD cmdlets on a management host; failures to inspect a group do not prevent attempting the add.
Import-Module ActiveDirectory -ErrorAction Stop

# Check each requested membership before adding it, making reruns safe.
foreach ($computer in $ComputerName) {
    foreach ($group in $Groups) {
        try {
            $members = Get-ADGroupMember -Identity $group -Server $Server -ErrorAction Stop |
                Select-Object -ExpandProperty SamAccountName
            if ($members -contains "$computer$") {
                Write-Host "[skip] $computer is already in $group"
                continue
            }
        } catch {
            Write-Host "[warn] could not read $group : $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Honor -WhatIf and -Confirm through ShouldProcess before changing Active Directory.
        if ($PSCmdlet.ShouldProcess("$computer -> $group", 'Add-ADGroupMember')) {
            try {
                Add-ADGroupMember -Identity $group -Members $computer `
                    -Credential $Credential -Server $Server -ErrorAction Stop
                Write-Host "[ok]   $computer added to $group"
            } catch {
                Write-Host "[fail] $computer -> $group : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}
