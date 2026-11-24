#Requires -Version 5.1
<#
.SYNOPSIS
    Copy the latest Brume-staged Dell driver pack locally and install its INF files.

.DESCRIPTION
    Prompts for the read-only SMB account instead of storing a share password in
    the image. Brume updates the Latitude 3440 pack on the share from Dell's
    official catalog; this script does not need client internet access.
    The first-logon batch handoff calls this script before the existing
    C:\firstrun.bat workflow.

.PARAMETER ShareRoot
    UNC path to the Brume Drivers share.

.PARAMETER Model
    Driver-pack folder under the share, for example Latitude-3440.
#>
[CmdletBinding()]
param(
    [string]$ShareRoot = '\\10.99.0.1\Drivers',
    [string]$Model = '',
    [string]$BasePack = 'VMD'
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
$driveName = 'JOGDrivers'
$transcriptStarted = $false
$logDirectory = Join-Path $env:ProgramData 'Brume\logs'
$logPath = Join-Path $logDirectory 'first-logon-driver-install.log'

try {
    # Keep an operator-visible transcript for troubleshooting the first-logon install.
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    Start-Transcript -Path $logPath -Append | Out-Null
    $transcriptStarted = $true

    # Driver installation modifies the Windows driver store and requires elevation.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this first-logon handoff as a local administrator.'
    }

    # Detect the model when the caller did not name a pack. This keeps the
    # first-logon bridge usable on every model the driver sync has published.
    if ([string]::IsNullOrWhiteSpace($Model)) {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $Model = ($cs.Model.ToUpperInvariant() -replace '[^A-Z0-9]+', '-').Trim('-')
        Write-Host "[Brume] Detected model folder: $Model"
    }
    if ([string]::IsNullOrWhiteSpace($Model) -or
        $Model -in @('.', '..') -or
        $Model -match '[\\/:*?"<>|]') {
        throw "Invalid driver-pack folder name: $Model"
    }

    # Prompt interactively; the share password is not embedded in the image or script.
    $credential = Get-Credential -UserName 'drivers' -Message "Read-only credentials for $ShareRoot"
    if (-not $credential) {
        throw 'Driver-share credential prompt was cancelled.'
    }

    # Map the share with the supplied read-only account for this PowerShell process only.
    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
    }
    New-PSDrive -Name $driveName -PSProvider FileSystem -Root $ShareRoot `
        -Credential $credential -Scope Script -ErrorAction Stop | Out-Null

    # Confirm that the requested model pack exists before copying anything.
    $source = Join-Path -Path "$driveName`:" -ChildPath $Model
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Driver pack not found: $ShareRoot\$Model"
    }

    # Stage the packs on the system drive because Dell extraction and pnputil use local files.
    $stagingRoot = Join-Path $env:ProgramData 'Brume\drivers'
    $modelStaging = Join-Path $stagingRoot $Model
    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    if (Test-Path -LiteralPath $modelStaging) {
        Remove-Item -LiteralPath $modelStaging -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $modelStaging | Out-Null

    # Copy through the PowerShell drive; external tools cannot resolve a PSDrive path.
    Copy-Item -Path (Join-Path $source '*') -Destination $modelStaging -Recurse -Force
    $packFolders = @($Model)

    # Install the storage base pack as well as the model pack. A RAID machine
    # may boot from the image but still need iaStorVD bound to its controller.
    if (-not [string]::IsNullOrWhiteSpace($BasePack) -and $BasePack -ne $Model) {
        $baseSource = Join-Path -Path "$driveName`:" -ChildPath $BasePack
        if (Test-Path -LiteralPath $baseSource -PathType Container) {
            $baseStaging = Join-Path $stagingRoot $BasePack
            if (Test-Path -LiteralPath $baseStaging) { Remove-Item -LiteralPath $baseStaging -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $baseStaging | Out-Null
            Copy-Item -Path (Join-Path $baseSource '*') -Destination $baseStaging -Recurse -Force
            $packFolders += $BasePack
        } else {
            Write-Host "[Brume] Base driver pack not found: $ShareRoot\$BasePack"
        }
    }

    # Extract the Dell driver-pack executable silently, verifying its trusted signer first.
    $dellPack = Join-Path $modelStaging 'DellDriverPack.exe'
    $driverRoot = $stagingRoot
    if (Test-Path -LiteralPath $dellPack -PathType Leaf) {
        $signature = Get-AuthenticodeSignature -FilePath $dellPack
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $signature.SignerCertificate.Subject -notmatch '(?i)(^|,\s*)CN=Dell( Technologies)? Inc\.') {
            throw "Dell driver pack signature is not valid or is not signed by Dell Inc. (status: $($signature.Status))."
        }

        $extractPath = Join-Path $modelStaging 'extracted'
        if (Test-Path -LiteralPath $extractPath) {
            Remove-Item -LiteralPath $extractPath -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
        Write-Host "Extracting the Dell driver pack ($([math]::Round((Get-Item $dellPack).Length / 1GB, 1)) GB)."
        $extractProcess = Start-Process -FilePath $dellPack `
            -ArgumentList @('/s', "/e=$extractPath") -Wait -PassThru -WindowStyle Hidden
        if ($extractProcess.ExitCode -ne 0) {
            throw "Dell driver-pack extraction failed with exit code $($extractProcess.ExitCode)."
        }
    }

    # Require INF files in either the Dell extraction or a legacy uploaded pack.
    $infs = @(Get-ChildItem -Path $driverRoot -Filter '*.inf' -Recurse -File)
    if ($infs.Count -eq 0) {
        throw "No INF files found in $ShareRoot ($($packFolders -join ', ')) after checking the Dell pack and legacy driver files."
    }

    # Install every INF in the staged packs and preserve pnputil's output in the transcript.
    Write-Host "Installing $($infs.Count) driver INF file(s) from $ShareRoot ($($packFolders -join ', '))."
    & "$env:SystemRoot\System32\pnputil.exe" /add-driver $driverRoot /subdirs /install
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -notin @(0, 3010)) {
        throw "pnputil failed with exit code $installExitCode."
    }

    # A reboot-required result is still a successful install; the following setup
    # workflow can request its normal restart after the device has been named.
    if ($installExitCode -eq 3010) {
        Write-Host 'Drivers installed; Windows reports that a reboot is required.'
    } else {
        Write-Host 'Driver installation completed.'
    }
} catch {
    # Return a failing status so the batch handoff does not continue to domain setup.
    Write-Host "[Brume] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    # Remove the temporary SMB mapping but retain the local driver pack and log for inspection.
    if (Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
    }

    # Close the transcript when it was successfully started.
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

# Report success or failure to the calling batch file.
exit $exitCode
