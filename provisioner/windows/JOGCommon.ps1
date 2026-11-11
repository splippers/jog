# JOGCommon.ps1 — shared helpers for the JOG Windows provisioner.
# PowerShell 5.1 compatible. Dot-source from each stage script.

# Write a timestamped message to the console and, when configured, the provisioner log file.
function Write-JOGLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO',
        [string]$LogFile = $script:JOGLogFile
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        try {
            $dir = Split-Path -Parent $LogFile
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

# Read an optional property from a config/state object, returning a default when absent or null.
function Get-JOGProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

# Build the standard result object returned by each provisioning stage.
function New-JOGResult {
    param(
        [bool]$Success,
        [bool]$RebootRequired = $false,
        [string]$Message = '',
        $Data = $null
    )
    [pscustomobject]@{
        Success        = $Success
        RebootRequired = $RebootRequired
        Message        = $Message
        Data           = $Data
    }
}

# Return whether the current process has the elevated rights required for provisioning.
function Test-JOGAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.Name -eq 'NT AUTHORITY\SYSTEM') { return $true }
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Restrict a sensitive file or directory to SYSTEM and local Administrators.
function Set-JOGFileAcl {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    if (-not (Test-Path $Path)) { return }
    if ($Directory) {
        $icaclsArgs = @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    } else {
        $icaclsArgs = @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:F', '*S-1-5-32-544:F')
    }
    try { & icacls.exe @icaclsArgs | Out-Null } catch { }
}

# Run a native executable and capture its output, exit code, and success classification.
function Invoke-JOGProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0)
    )
    try {
        $output = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
        $text = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
        [pscustomobject]@{
            ExitCode = $code
            Output   = $text
            Success  = ($SuccessExitCodes -contains $code)
        }
    } catch {
        [pscustomobject]@{
            ExitCode = -1
            Output   = $_.Exception.Message
            Success  = $false
        }
    }
}

# Read hardware identity fields used for model-driver selection and deterministic naming.
function Get-JOGModelInfo {
    try {
        $cs   = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $bb   = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop
        $prod = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        [pscustomobject]@{
            Manufacturer = [string]$cs.Manufacturer
            Model        = [string]$cs.Model
            Serial       = [string]$bios.SerialNumber
            BaseBoard    = [string]$bb.Product
            ProductName  = [string]$prod.Name
        }
    } catch {
        [pscustomobject]@{
            Manufacturer = ''
            Model        = ''
            Serial       = ''
            BaseBoard    = ''
            ProductName  = ''
        }
    }
}

# Normalize a hardware or site value into an uppercase, hyphen-separated name fragment.
function ConvertTo-JOGSlug {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    ($Value.ToUpperInvariant() -replace '[^A-Z0-9]+', '-').Trim('-')
}

# Convert configured domain-join credentials into a PSCredential, or return null if incomplete.
function Get-JOGDomainCredential {
    param($Config)
    $join = Get-JOGProperty $Config 'DomainJoin' $null
    $user = Get-JOGProperty $join 'User' ''
    $pass = Get-JOGProperty $join 'Password' ''
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) { return $null }
    $secure = ConvertTo-SecureString $pass -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential($user, $secure)
}

# Parse dsregcmd status into the hybrid-join fields the state machine needs.
function Get-JOGDsRegStatus {
    $raw = ''
    try { $raw = (& dsregcmd.exe /status 2>&1 | Out-String) } catch { }
    $deviceAuth = ''
    if ($raw -match '(?m)^\s*DeviceAuthStatus\s*:\s*(\S+)') { $deviceAuth = $Matches[1] }
    [pscustomobject]@{
        Raw              = $raw
        AzureAdJoined    = ($raw -match '(?m)^\s*AzureAdJoined\s*:\s*YES')
        DomainJoined     = ($raw -match '(?m)^\s*DomainJoined\s*:\s*YES')
        DeviceAuthStatus = $deviceAuth
    }
}

# Check the Windows computer-system flag and return false if the query is unavailable.
function Test-JOGDomainJoined {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return [bool]$cs.PartOfDomain
    } catch { return $false }
}

# Generate a numeric BitLocker PIN without integer conversion or leading-zero ambiguity.
function New-JOGPin {
    param([int]$Length = 6)
    if ($Length -lt 6) { $Length = 6 }
    if ($Length -gt 20) { $Length = 20 }
    # Generate digits directly: 10^19 exceeds Int64, so the old Pow/Random
    # approach overflowed for long PINs. First digit is non-zero.
    $digits = New-Object System.Text.StringBuilder
    [void]$digits.Append((Get-Random -Minimum 1 -Maximum 10))
    for ($i = 1; $i -lt $Length; $i++) {
        [void]$digits.Append((Get-Random -Minimum 0 -Maximum 10))
    }
    return $digits.ToString()
}

# Remove an existing SMB mapping for the share before or after credentialed access.
function Remove-JOGSmbMapping {
    param([string]$RemotePath)
    if ([string]::IsNullOrWhiteSpace($RemotePath)) { return }
    try {
        $existing = Get-SmbMapping -RemotePath $RemotePath -ErrorAction SilentlyContinue
        if ($existing) { Remove-SmbMapping -RemotePath $RemotePath -Force -ErrorAction SilentlyContinue | Out-Null }
    } catch { }
}

# Map a share with the configured credentials, falling back to `net use` if needed.
function New-JOGSmbMapping {
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password
    )
    Remove-JOGSmbMapping -RemotePath $RemotePath
    try {
        New-SmbMapping -RemotePath $RemotePath -UserName $UserName -Password $Password -Persistent $false -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $r = Invoke-JOGProcess -FilePath 'net.exe' -ArgumentList @('use', $RemotePath, "/user:$UserName", $Password, '/persistent:no')
        if (-not $r.Success) {
            Write-JOGLog -Message "SMB mapping failed for $RemotePath : $($r.Output)" -Level ERROR
            return $false
        }
        return $true
    }
}
