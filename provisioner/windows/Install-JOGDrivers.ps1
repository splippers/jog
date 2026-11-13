#Requires -Version 5.1
<#
.SYNOPSIS
    Stage: pull the model driver pack from the JOG Samba share and install it with pnputil.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Config,
    [Parameter(Mandatory)][string]$LogFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JOGCommon.ps1')

# Load the share policy and fail clearly if the driver share is not configured.
$share = Get-JOGProperty $Config 'DriverShare' $null
if (-not $share) {
    Write-JOGLog "No DriverShare block in the config." -Level ERROR -LogFile $LogFile
    return (New-JOGResult $false $false 'No DriverShare configuration')
}

$unc  = [string](Get-JOGProperty $share 'Unc' '\\10.99.0.1\Drivers')
$user = [string](Get-JOGProperty $share 'ReadUser' 'drivers')
$pass = [string](Get-JOGProperty $share 'ReadPassword' '')
$fallback = [string](Get-JOGProperty $share 'Fallback' 'Default')
$manifestName = [string](Get-JOGProperty $share 'Manifest' 'manifest.json')
$basePacks = @(Get-JOGProperty $share 'BasePacks' @('VMD'))

if ([string]::IsNullOrWhiteSpace($pass)) {
    Write-JOGLog "DriverShare.ReadPassword is empty; cannot map $unc." -Level ERROR -LogFile $LogFile
    return (New-JOGResult $false $false 'Driver share password is empty')
}

# Build likely folder names from the machine's hardware identity.
$info = Get-JOGModelInfo
$candidates = @(
    $info.Model,
    $info.BaseBoard,
    $info.ProductName,
    ("{0} {1}" -f $info.Manufacturer, $info.Model)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

Write-JOGLog ("Model: {0} | BaseBoard: {1} | Product: {2}" -f $info.Model, $info.BaseBoard, $info.ProductName) -LogFile $LogFile

# Prefer an explicit model-map match; otherwise use the normalized Windows model string.
$modelMap = Get-JOGProperty $share 'ModelMap' $null
$folder = $null
if ($modelMap) {
    foreach ($entry in $modelMap.PSObject.Properties) {
        foreach ($candidate in $candidates) {
            if ($candidate -like "*$($entry.Name)*" -or $candidate -eq $entry.Name) {
                $folder = [string]$entry.Value
                Write-JOGLog "ModelMap matched '$($entry.Name)' -> '$folder'" -LogFile $LogFile
                break
            }
        }
        if ($folder) { break }
    }
}
if (-not $folder) {
    $folder = ConvertTo-JOGSlug $info.Model
    Write-JOGLog "No ModelMap entry; derived folder '$folder' from the model." -LogFile $LogFile
}

$mapped = New-JOGSmbMapping -RemotePath $unc -UserName $user -Password $pass
# Do not continue into file operations unless the share credentials were accepted.
if (-not $mapped) {
    return (New-JOGResult $false $false "Cannot map $unc as $user")
}

$staging = Join-Path $env:ProgramData 'JOG\drivers'
$robolog = Join-Path (Split-Path -Parent $LogFile) 'robocopy-drivers.log'
$selected = @()

try {
    # The sync script writes manifest.json next to the model folders. Prefer
    # that mapping because an operator may have renamed a folder or added an
    # alias; fall back to the deterministic model slug.
    $manifestPath = Join-Path $unc $manifestName
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
            $manifestFolder = $null
            foreach ($entry in @($manifest.models)) {
                if (-not $entry.folder) { continue }
                $names = @($entry.model) + @($entry.aliases)
                foreach ($name in $names) {
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    foreach ($candidate in $candidates) {
                        if ((ConvertTo-JOGModelKey $candidate) -eq (ConvertTo-JOGModelKey $name)) {
                            $manifestFolder = [string]$entry.folder
                            Write-JOGLog "Manifest matched '$name' -> '$manifestFolder'" -LogFile $LogFile
                            break
                        }
                    }
                    if ($manifestFolder) { break }
                }
                if ($manifestFolder) { break }
            }
            if ($manifestFolder) { $folder = $manifestFolder }
        } catch {
            Write-JOGLog "Could not read $manifestPath : $($_.Exception.Message)" -Level WARN -LogFile $LogFile
        }
    }

    # Install the base pack (VMD/iaStorVD) first, then the model pack, then
    # the generic fallback. A newly imaged RAID machine needs the storage
    # driver even when its model pack is missing.
    foreach ($base in $basePacks) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        if (Test-Path (Join-Path $unc $base)) {
            if ($selected -notcontains $base) { $selected += $base }
        } else {
            Write-JOGLog "Base driver pack '$base' is not present under $unc." -Level WARN -LogFile $LogFile
        }
    }

    $modelFolder = $null
    foreach ($candidateFolder in @($folder, $fallback)) {
        if ([string]::IsNullOrWhiteSpace($candidateFolder)) { continue }
        if (Test-Path (Join-Path $unc $candidateFolder)) {
            $modelFolder = $candidateFolder
            break
        }
    }
    if (-not $modelFolder) {
        $available = @()
        try { $available = Get-ChildItem -Path $unc -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name } catch { }
        $msg = "No driver folder '$folder' (or '$fallback') under $unc. Available: $($available -join ', ')"
        Write-JOGLog $msg -Level ERROR -LogFile $LogFile
        return (New-JOGResult $false $false $msg)
    }
    if ($selected -notcontains $modelFolder) { $selected += $modelFolder }

    # Mirror each selected pack locally so pnputil does not install from a network path.
    if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    foreach ($packFolder in $selected) {
        $target = Join-Path $staging $packFolder
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-JOGLog "Copying $unc\$packFolder to $target" -LogFile $LogFile
        $rc = Invoke-JOGProcess -FilePath 'robocopy.exe' -ArgumentList @(
            (Join-Path $unc $packFolder), $target,
            '/MIR', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', "/LOG:$robolog"
        )
        if ($rc.ExitCode -ge 8) {
            $msg = "robocopy failed (exit $($rc.ExitCode)) for $packFolder; see $robolog"
            Write-JOGLog $msg -Level ERROR -LogFile $LogFile
            return (New-JOGResult $false $false $msg)
        }
    }

    # pnputil requires extracted INF files; report missing or failed installation as a stage error.
    $infs = @(Get-ChildItem -Path $staging -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) {
        $msg = "No .inf files in $($selected -join ', '). Extract the vendor pack (CAB/EXE) before uploading."
        Write-JOGLog $msg -Level ERROR -LogFile $LogFile
        return (New-JOGResult $false $false $msg)
    }
    Write-JOGLog "Found $($infs.Count) INF file(s); running pnputil." -LogFile $LogFile

    $pnp = Invoke-JOGProcess -FilePath 'pnputil.exe' -ArgumentList @(
        '/add-driver', $staging, '/subdirs', '/install'
    ) -SuccessExitCodes @(0, 259, 3010)
    Write-JOGLog "pnputil exit $($pnp.ExitCode)" -LogFile $LogFile
    if (-not [string]::IsNullOrWhiteSpace($pnp.Output)) {
        Write-JOGLog "pnputil output: $($pnp.Output)" -LogFile $LogFile
    }
    if (-not $pnp.Success) {
        return (New-JOGResult $false $false "pnputil failed (exit $($pnp.ExitCode))")
    }

    $reboot = ($pnp.ExitCode -eq 3010)
    return (New-JOGResult $true $reboot "Installed $($infs.Count) INF file(s) from $($selected -join ', ')")
}
finally {
    # Always remove network credentials and the temporary driver copy, including on failure.
    Remove-JOGSmbMapping -RemotePath $unc
    if (Test-Path $staging) { Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
