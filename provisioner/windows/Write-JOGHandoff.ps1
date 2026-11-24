#Requires -Version 5.1
<#
.SYNOPSIS
    Stage: leave an air-gapped device ready for corporate enrollment.

.DESCRIPTION
    Runs after hostname and driver installation when ProvisioningMode is
    AirGapped. It does not attempt a domain join, Entra hybrid join, group
    add, or BitLocker escrow, because those require the corporate network.

    It writes a plain-language handoff note, puts a "Complete Corporate
    Enrollment" shortcut on the public desktop, records the handoff state in
    the registry, and removes the driver-share and domain-join passwords from
    the on-disk config. The resume script prompts for a delegated join
    account when the device reaches Corporate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$LogFile,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'haar-provisioning.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

$info = Get-JOGModelInfo
$hybridBlock = Get-JOGProperty $Config 'HybridJoin' $null
$domain = [string](Get-JOGProperty $Config 'Domain' 'corporate.example.com')
$hybrid = [bool](Get-JOGProperty $hybridBlock 'Enabled' $true)
$resumeScript = Join-Path $PSScriptRoot 'Resume-JOGCorporateEnrollment.ps1'
$handoffFile = Join-Path $PSScriptRoot 'AWAITING-CORPORATE.txt'

if (-not (Test-Path $resumeScript)) {
    return (New-JOGResult $false $false "Missing resume script: $resumeScript")
}

$lines = @(
    'Brume - AWAITING CORPORATE ENROLLMENT',
    '====================================',
    '',
    "Device      : $env:COMPUTERNAME",
    "Model       : $($info.Manufacturer) $($info.Model)",
    "Serial      : $($info.Serial)",
    "Prepared    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Domain      : $domain",
    "Hybrid join : $hybrid",
    '',
    'Imaging and driver installation are complete. This device has NOT been',
    'joined to the corporate domain, added to AD groups, or BitLocker-encrypted',
    'because the imaging network is isolated from Corporate.',
    '',
    'To finish enrollment:',
    '  1. Connect the device to the corporate network (wired or VPN).',
    '  2. Sign in with a local administrator account.',
    '  3. Double-click "Complete Corporate Enrollment" on the desktop, or run:',
    '',
    "       powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`"",
    '',
    '  4. Supply a delegated domain-join account when prompted.',
    '',
    'The resume script checks that a domain controller is reachable, joins the',
    'domain, waits for Entra hybrid join, adds the configured AD groups, enables',
    'BitLocker, and verifies recovery-password escrow. The device may restart',
    'during this process and will continue automatically after the restart.',
    '',
    'Do not reimage the device. The provisioner state is retained in',
    "$PSScriptRoot\Provisioning.json."
)
$lines | Set-Content -Path $handoffFile -Encoding UTF8
Set-JOGFileAcl -Path $handoffFile

# Put the instructions and the elevated resume shortcut where a technician
# will see them, without relying on a particular user profile.
$publicDesktop = Join-Path $env:PUBLIC 'Desktop'
if (-not (Test-Path $publicDesktop)) { $publicDesktop = 'C:\Users\Public\Desktop' }
New-Item -ItemType Directory -Force -Path $publicDesktop | Out-Null
Copy-Item -Path $handoffFile -Destination (Join-Path $publicDesktop 'Brume - Awaiting Corporate.txt') -Force

$shortcutPath = Join-Path $publicDesktop 'Complete Corporate Enrollment.lnk'
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = 'Join this Brume-imaged device to Corporate and finish provisioning'
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,21"
    $shortcut.Save()
    Write-JOGLog "Created handoff shortcut: $shortcutPath" -LogFile $LogFile
} catch {
    Write-JOGLog "Could not create the desktop shortcut: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
}

# Record the handoff in the registry so inventory and support can see it
# without reading the provisioning state file.
try {
    $key = 'HKLM:\SOFTWARE\Brume'
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name 'State' -Value 'AWAITING_CORPORATE' -Type String
    Set-ItemProperty -Path $key -Name 'PreparedAt' -Value (Get-Date).ToString('o') -Type String
    Set-ItemProperty -Path $key -Name 'Model' -Value ([string]$info.Model) -Type String
    Set-ItemProperty -Path $key -Name 'Serial' -Value ([string]$info.Serial) -Type String
} catch {
    Write-JOGLog "Could not write the Brume registry handoff state: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
}

# The resume phase prompts for the join password; do not leave it on an
# air-gapped device. The driver-share read password is also no longer needed.
try {
    if ($Config.PSObject.Properties['DriverShare']) { $Config.DriverShare.ReadPassword = '' }
    if ($Config.PSObject.Properties['DomainJoin']) { $Config.DomainJoin.Password = '' }
    $Config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigPath -Encoding UTF8
    Set-JOGFileAcl -Path $ConfigPath
    Write-JOGLog 'Cleared driver-share and domain-join passwords from the handoff config.' -LogFile $LogFile
} catch {
    Write-JOGLog "Could not sanitise the handoff config: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
}

Write-JOGLog "Device is AWAITING_CORPORATE. Handoff note: $handoffFile" -LogFile $LogFile
return (New-JOGResult $true $false "Awaiting corporate enrollment; run $shortcutPath")
