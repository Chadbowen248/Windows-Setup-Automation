<#
.SYNOPSIS
    Windows Pro Workstation Pre-AD-Join Setup Automation

.DESCRIPTION
    Automates the standard set of configuration steps performed on every
    new Windows Pro workstation before it is joined to Active Directory.

    Designed for maximum convenience: minimal prompts, clear progress,
    and a final summary. Zero-install friction is the top priority.

.NOTES
    - Must be run with administrative privileges.
    - Some steps are interactive (e.g. local admin password).
    - Idempotency and safe re-runs are goals where practical.
#>

# ASCII-ONLY RULE (enforced going forward):
# This script uses only plain ASCII characters in source code, strings,
# and comments. No Unicode (e.g. no checkmarks, fancy quotes, etc.).
# Reason: PowerShell 5.1 on Windows is extremely sensitive to file encoding
# (UTF-8 without BOM, CRLF, etc.). Non-ASCII chars have caused "phantom"
# parse errors like "string missing the terminator" and cascading brace
# failures even when the logic was correct. All output uses [OK], - etc.

[CmdletBinding()]
param(
    [string]$LocalAdminPassword,
    [string]$PasswordFile,   # Path to ACL-restricted temp file (plain or base64). Preferred for wrappers.
    [switch]$AssumeDesktop,
    [switch]$AssumeLaptop,
    [switch]$Simulate,       # Run in simulation mode (no real system changes, useful for testing on non-Windows or dry-runs)
    [switch]$PauseOnExit     # Pause (wait for key) before exiting. Automatically passed by the .cmd launcher.
)

$ScriptVersion = '0.1.0'
$ScriptCommit = 'd273b24'   # Update this when you commit changes
$ErrorActionPreference = 'Stop'

#region Helpers

function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    if (Test-Admin) { return }

    Write-Warning "Administrative privileges required. Relaunching as Administrator..."
    Write-Host "  (You may see a UAC prompt.)" -ForegroundColor Yellow

    # Escape special characters (especially &) in values that will end up on the command line.
    # This is critical because -Verb RunAs often involves cmd.exe parsing for the new process.
    $safeScriptPath = Get-EscapedForArgument $PSCommandPath

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$safeScriptPath`""
    )

    # Forward non-sensitive switches
    if ($AssumeDesktop) { $argList += '-AssumeDesktop' }
    if ($AssumeLaptop)  { $argList += '-AssumeLaptop' }
    if ($PauseOnExit)   { $argList += '-PauseOnExit' }
    if ($Simulate)      { $argList += '-Simulate' }

    # Password passthrough (two paths):
    # 1. $PasswordFile (preferred for wrappers): only the *path* is passed.
    #    Caller creates an ACL'd temp file; we read + delete in finally.
    #    We escape & (and potentially other cmd-special chars) in the path value.
    # 2. $LocalAdminPassword (base64 encoded): for direct / simple cases.
    #    Base64 is safe from most special chars (including &), but we still quote the value.
    if ($PasswordFile) {
        $safeFile = Get-EscapedForArgument $PasswordFile
        $argList += '-PasswordFile', "`"$safeFile`""
    } elseif ($LocalAdminPassword) {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($LocalAdminPassword)
        $encoded = [Convert]::ToBase64String($bytes)
        $argList += '-LocalAdminPassword', "`"$encoded`""
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "    - $Message (already configured or skipped)" -ForegroundColor DarkGray
}

#endregion

#region New Foundation Helpers (PR 1)

$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {
    param(
        [string]$Step,
        [ValidateSet('Success','Skipped','Failed','Warning')][string]$Status,
        [string]$Details
    )
    $script:Results.Add([pscustomobject]@{
        Step      = $Step
        Status    = $Status
        Details   = $Details
        Timestamp = Get-Date
    })
}

function Get-BuiltInAdministrator {
    # Prefer SID (stable across localizations on non-English Windows)
    $sid = (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE 'S-1-5-21-%-500'" -ErrorAction SilentlyContinue).SID
    if ($sid) {
        return Get-LocalUser -SID $sid -ErrorAction SilentlyContinue
    }
    # Fallback to English name (common on en-US / enterprise images)
    return Get-LocalUser -Name 'Administrator' -ErrorAction SilentlyContinue
}

function Get-MachineType {
    param([switch]$AssumeDesktop, [switch]$AssumeLaptop)

    if ($AssumeLaptop)  { return 'Laptop' }
    if ($AssumeDesktop) { return 'Desktop' }

    # Multi-factor auto detection (PS 5.1 compatible)
    try {
        $chassis = (Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
        $hasBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        $pcType = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PCSystemType

        # Common laptop/notebook chassis types
        $laptopChassis = @(8,9,10,11,12,14,18,21,31,32)
        if ($chassis -and ($chassis | Where-Object { $_ -in $laptopChassis })) {
            return 'Laptop'
        }
        if ($hasBattery -or ($pcType -eq 2)) {  # 2 = Mobile
            return 'Laptop'
        }
        return 'Desktop'
    } catch {
        # Last resort prompt (rare)
        $ans = Read-Host "Is this a Laptop or Desktop? (L/D)"
        if ($ans -match '^[Ll]') { return 'Laptop' } else { return 'Desktop' }
    }
}

function Get-EscapedForArgument {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    # Escape & (command separator in cmd.exe) because Start-Process -Verb RunAs
    # often results in a command line processed by cmd for the elevated instance.
    # This prevents the argument list from being split on & in paths, passwords (pre-encode), etc.
    # Note: base64 encoded values are already safe (no &), but we still quote them.
    $Value = $Value -replace '&', '^&'
    return $Value
}

#endregion

#region Step Implementations (PR 1: wiring + results only; real logic in later PRs)

function Set-UACNeverNotify {
    Write-Step "Setting UAC to Never Notify"
    if ($Simulate) {
        Add-Result 'UAC' 'Simulated' 'UAC set to never notify'
        Write-Success "UAC set to never notify (simulated)"
        return
    }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $admin = (Get-ItemProperty -Path $key -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
    $secure = (Get-ItemProperty -Path $key -Name PromptOnSecureDesktop -ErrorAction SilentlyContinue).PromptOnSecureDesktop
    if ($admin -eq 0 -and $secure -eq 0) {
        Write-Skip "UAC already set to never notify"
        Add-Result 'UAC' 'Skipped' 'Already configured'
        return
    }
    Set-ItemProperty -Path $key -Name ConsentPromptBehaviorAdmin -Value 0 -Type DWord
    Set-ItemProperty -Path $key -Name PromptOnSecureDesktop -Value 0 -Type DWord
    Add-Result 'UAC' 'Success' 'UAC set to never notify'
    Write-Success "UAC set to never notify"
}

function Set-DateTimeAutomatic {
    Write-Step "Configuring Date and Time (automatic + location-based)"
    if ($Simulate) {
        Add-Result 'DateTime' 'Simulated' 'Date & time set to automatic + location-based'
        Write-Success "Date and Time configured (simulated)"
        return
    }
    # Time sync
    Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name w32time -ErrorAction SilentlyContinue
    w32tm /config /update | Out-Null
    w32tm /resync | Out-Null
    # Time zone auto + location
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' -Name 'Start' -Value 3 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value' -Value 'Allow' -Force -ErrorAction SilentlyContinue
    Add-Result 'DateTime' 'Success' 'Date & time set to automatic + location-based'
    Write-Success "Date and Time configured"
}

function Set-PowerPlan {
    param([string]$MachineType)
    Write-Step "Configuring Power Plan for $MachineType"
    if ($Simulate) {
        Add-Result 'PowerPlan' 'Simulated' "Power plan for $MachineType (simulated)"
        Write-Success "Power plan updated (simulated)"
        return
    }
    if ($MachineType -eq 'Desktop') {
        powercfg /change monitor-timeout-ac 60 | Out-Null
        powercfg /change standby-timeout-ac 0 | Out-Null
    } else {
        # Laptop: battery vs plugged
        powercfg /change monitor-timeout-dc 15 | Out-Null
        powercfg /change standby-timeout-dc 20 | Out-Null
        powercfg /change monitor-timeout-ac 15 | Out-Null
        powercfg /change standby-timeout-ac 0 | Out-Null
    }
    Add-Result 'PowerPlan' 'Success' "Power plan configured for $MachineType"
    Write-Success "Power plan updated"
}

function Set-LocalAdministrator {
    Write-Step "Configuring Local Administrator Account"

    $admin = Get-BuiltInAdministrator
    if (-not $admin) {
        Add-Result 'LocalAdmin' 'Failed' 'Built-in Administrator account not found (even by SID)'
        Write-Warning "Could not locate built-in Administrator account by SID or name."
        return
    }

    # Auto-discover pw.txt in the same directory as the script (for simple USB/drop-and-run use).
    # This is a fallback only. Explicit -LocalAdminPassword or -PasswordFile take precedence.
    # File should contain the plain-text password (one line, will be trimmed).
    if (-not $LocalAdminPassword -and -not $PasswordFile) {
        $pwFile = Join-Path $PSScriptRoot 'pw.txt'
        if (Test-Path $pwFile -PathType Leaf) {
            $LocalAdminPassword = (Get-Content -Path $pwFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($LocalAdminPassword) {
                Write-Host "Using password from pw.txt (same directory as script)" -ForegroundColor Yellow
            }
        }
    }

    # Password source handling
    $plain = $null
    $passwordSourceProvided = $false

    if ($PasswordFile -and (Test-Path $PasswordFile)) {
        if (-not $Simulate) {
            try {
                $content = Get-Content -Path $PasswordFile -Raw -ErrorAction Stop
                try {
                    $bytes = [Convert]::FromBase64String($content.Trim())
                    $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
                } catch { $plain = $content.Trim() }
            } finally {
                Remove-Item -Path $PasswordFile -Force -ErrorAction SilentlyContinue
            }
        }
        $passwordSourceProvided = $true
    } elseif ($LocalAdminPassword) {
        if (-not $Simulate) {
            try {
                $bytes = [Convert]::FromBase64String($LocalAdminPassword)
                $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
            } catch { $plain = $LocalAdminPassword }
        }
        $passwordSourceProvided = $true
    }

    # Idempotency guard (skip prompt entirely on re-runs if already good, and no password source was provided)
    if ($admin.Enabled -and $admin.PasswordNeverExpires -and -not $passwordSourceProvided) {
        Write-Skip "Local Administrator ($($admin.Name)) already enabled with PasswordNeverExpires=true"
        Add-Result 'LocalAdmin' 'Skipped' 'Account already in desired state'
        return
    }

    if ($plain) {
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    } elseif (-not $Simulate) {
        $secure = Read-Host -Prompt "Enter password for local Administrator account" -AsSecureString
    } else {
        # In simulation with no password source: use a dummy so we exercise the "set" path for testing
        $secure = ConvertTo-SecureString 'SimulatedP@ssw0rd123!' -AsPlainText -Force
    }

    if (-not $Simulate) {
        if (-not $admin.Enabled) {
            Enable-LocalUser -SID $admin.SID
        }
        Set-LocalUser -SID $admin.SID -Password $secure -PasswordNeverExpires $true

        Add-Result 'LocalAdmin' 'Success' "Administrator account ($($admin.Name)) enabled + password set + never expires"
        Write-Success "Local Administrator configured"
    } else {
        Add-Result 'LocalAdmin' 'Simulated' "Would configure local admin (password source provided: $passwordSourceProvided)"
        Write-Success "Local Administrator (simulated)"
    }
}

function Enable-RemoteDesktop {
    Write-Step "Enabling Remote Desktop"
    if ($Simulate) {
        Add-Result 'RemoteDesktop' 'Simulated' 'Remote Desktop enabled (simulated)'
        Write-Success "Remote Desktop enabled (simulated)"
        return
    }
    $tsKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    $rdpKey = "$tsKey\WinStations\RDP-Tcp"
    $deny = (Get-ItemProperty -Path $tsKey -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    $nla = (Get-ItemProperty -Path $rdpKey -Name UserAuthentication -ErrorAction SilentlyContinue).UserAuthentication
    if ($deny -eq 0 -and $nla -eq 1) {
        Write-Skip "Remote Desktop already enabled with NLA"
        Add-Result 'RemoteDesktop' 'Skipped' 'Already configured'
        return
    }
    Set-ItemProperty -Path $tsKey -Name fDenyTSConnections -Value 0
    Set-ItemProperty -Path $rdpKey -Name UserAuthentication -Value 1
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
    Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    Add-Result 'RemoteDesktop' 'Success' 'Remote Desktop enabled with NLA'
    Write-Success "Remote Desktop enabled"
}

function Uninstall-DellOptimizer {
    Write-Step "Checking for and uninstalling Dell Optimizer"
    if ($Simulate) {
        Add-Result 'DellOptimizer' 'Simulated' 'Dell Optimizer uninstalled (simulated)'
        Write-Success "Dell Optimizer handled (simulated)"
        return
    }
    $mfr = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    if ($mfr -notmatch 'Dell') {
        Write-Skip "Not a Dell machine"
        Add-Result 'DellOptimizer' 'Skipped' 'Not a Dell machine'
        return
    }
    # Stop services
    Get-Service -Name '*DellOptimizer*' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    # Try Get-Package first
    $pkg = Get-Package -Name '*Dell*Optimizer*' -ErrorAction SilentlyContinue
    if ($pkg) {
        $pkg | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null
        Add-Result 'DellOptimizer' 'Success' 'Dell Optimizer uninstalled via Get-Package'
        Write-Success "Dell Optimizer uninstalled"
        return
    }
    # Fallback: registry uninstall strings
    $uninst = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Get-ItemProperty | Where-Object { $_.DisplayName -like '*Dell*Optimizer*' -and $_.UninstallString }
    if ($uninst) {
        foreach ($u in $uninst) {
            $cmd = $u.UninstallString
            if ($cmd -match 'msiexec') {
                $cmd += ' /qn /norestart'
            } else {
                $cmd += ' /remove /silent'
            }
            cmd /c $cmd | Out-Null
        }
        Add-Result 'DellOptimizer' 'Success' 'Dell Optimizer uninstalled via registry'
        Write-Success "Dell Optimizer uninstalled"
        return
    }
    Write-Skip "Dell Optimizer not present"
    Add-Result 'DellOptimizer' 'Skipped' 'Not present'
}

function Uninstall-NonEnglishOffice {
    Write-Step "Removing non-English Office 365 installations"
    if ($Simulate) {
        Add-Result 'OfficeLanguages' 'Simulated' 'Non-English Office removed (simulated)'
        Write-Success "Non-English Office versions removed (simulated)"
        return
    }
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $c2r = Get-ChildItem $keys -ErrorAction SilentlyContinue | Get-ItemProperty |
        Where-Object {
            $_.DisplayName -match 'Microsoft (365|Office|Office 16|M365)' -and
            $_.DisplayName -match ' - [a-z]{2}-[a-z]{2}' -and
            $_.DisplayName -notmatch '- ?en-us' -and
            $_.UninstallString
        }
    if (-not $c2r) {
        Write-Skip "No non-English Office language packs found"
        Add-Result 'OfficeLanguages' 'Skipped' 'None found'
        return
    }
    $removed = @()
    foreach ($entry in $c2r) {
        $cmd = $entry.UninstallString
        if ($cmd -match 'msiexec') {
            $cmd += ' /qn /norestart'
        } else {
            $cmd += ' /quiet /norestart'
        }
        cmd /c $cmd | Out-Null
        $removed += $entry.DisplayName
    }
    Add-Result 'OfficeLanguages' 'Success' "Removed: $($removed -join '; ')"
    Write-Success "Non-English Office versions removed"
}

function Install-Chrome {
    Write-Step "Installing Google Chrome"
    if ($Simulate) {
        Add-Result 'Chrome' 'Simulated' 'Google Chrome installed (simulated)'
        Write-Success "Chrome installed (simulated)"
        return
    }
    # Idempotency check
    $present = winget list --id Google.Chrome --accept-source-agreements 2>$null
    if ($present -match 'Google.Chrome') {
        Write-Skip "Google Chrome already installed"
        Add-Result 'Chrome' 'Skipped' 'Already present'
        return
    }
    # Best-effort source update (non-fatal)
    winget source update --accept-source-agreements | Out-Null
    winget install --id Google.Chrome -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Add-Result 'Chrome' 'Success' 'Google Chrome installed'
    Write-Success "Chrome installed"
}

function Install-AdobeAcrobatReader {
    Write-Step "Installing Adobe Acrobat Reader"
    if ($Simulate) {
        Add-Result 'AcrobatReader' 'Simulated' 'Adobe Acrobat Reader installed (simulated)'
        Write-Success "Adobe Acrobat Reader installed (simulated)"
        return
    }
    $id = 'Adobe.Acrobat.Reader.64-bit'
    $present = winget list --id $id --accept-source-agreements 2>$null
    if ($present -match $id) {
        Write-Skip "Adobe Acrobat Reader already installed"
        Add-Result 'AcrobatReader' 'Skipped' 'Already present'
        return
    }
    winget source update --accept-source-agreements | Out-Null
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Add-Result 'AcrobatReader' 'Success' 'Adobe Acrobat Reader installed'
    Write-Success "Adobe Acrobat Reader installed"
}

#endregion

#region Main

# top level (runs in both contexts)
Write-Host "Windows Workstation Pre-AD Setup" -ForegroundColor Magenta
Write-Host "=================================" -ForegroundColor Magenta
Write-Host "Version: $ScriptVersion  Commit: $ScriptCommit  Simulate: $Simulate" -ForegroundColor DarkGray

if (-not $Simulate) {
    Request-Elevation   # if not admin: builds argList (with -PasswordFile path if supplied, else base64 -LocalAdminPassword), Start-Process -Verb RunAs, exit
}

# === ONLY ELEVATED (or Simulate) REACHES HERE ===

if ($Simulate) {
    $transcriptPath = 'SIMULATED-TRANSCRIPT.log'
    Write-Host "=== SIMULATION MODE ===" -ForegroundColor Yellow
    Write-Host "No elevation or system changes will be performed." -ForegroundColor Yellow
} else {
    $transcriptPath = Join-Path $env:TEMP "WindowsSetup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Start-Transcript -Path $transcriptPath -IncludeInvocationHeader
}

$machineType = 'Unknown'   # default in case of early exit before detection

try {
    if ($Simulate) {
        Write-Host "Script Version: $ScriptVersion (Commit $ScriptCommit) [SIMULATED]" -ForegroundColor DarkGray
        Write-Host "Computer      : SIMULATED-HOST"
        Write-Host "OS            : Simulated Windows 11 Pro"
        Write-Host "Manufacturer  : Simulated OEM / Simulated Model"
        Write-Host "PartOfDomain  : False"
    } else {
        Write-Host "Script Version: $ScriptVersion" -ForegroundColor DarkGray

        # Full machine info banner (elevated only)
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            Write-Host "Computer      : $($env:COMPUTERNAME)"
            Write-Host "OS            : $($os.Caption)"
            Write-Host "Manufacturer  : $($cs.Manufacturer) / $($cs.Model)"
            Write-Host "PartOfDomain  : $($cs.PartOfDomain)"
        } catch {
            Write-Host "Computer      : $($env:COMPUTERNAME)"
        }
    }

    if ($Simulate) {
        $machineType = if ($AssumeLaptop) { 'Laptop' } elseif ($AssumeDesktop) { 'Desktop' } else { 'Desktop' }
    } else {
        $machineType = Get-MachineType -AssumeDesktop:$AssumeDesktop -AssumeLaptop:$AssumeLaptop
    }
    Write-Host "Form Factor   : $machineType (auto-detected)" -ForegroundColor DarkGray

    # Execute the 9 steps (each records via Add-Result)
    Set-UACNeverNotify
    Set-DateTimeAutomatic
    Set-PowerPlan -MachineType $machineType
    Set-LocalAdministrator
    Enable-RemoteDesktop
    Uninstall-DellOptimizer
    Uninstall-NonEnglishOffice
    Install-Chrome
    Install-AdobeAcrobatReader

} finally {
    # Guaranteed cleanup for any password material (even on exceptions/Ctrl-C)
    Remove-Variable -Name LocalAdminPassword, PasswordFile, plain, secure -Scope Script -Force -ErrorAction SilentlyContinue
    if ($PasswordFile -and (Test-Path $PasswordFile)) {
        Remove-Item -Path $PasswordFile -Force -ErrorAction SilentlyContinue
    }

    if (-not $Simulate) {
        Stop-Transcript
    }

    # Always emit the structured results table + write the persistent report
    Write-Host "`n=================================" -ForegroundColor Magenta
    Write-Host "SETUP COMPLETE - SUMMARY REPORT" -ForegroundColor Green
    $script:Results | Format-Table -AutoSize -Wrap | Out-Host

    if ($Simulate) {
        $reportPath = ".\WindowsSetupReport-SIMULATED.txt"
        $reportLines = @(
            "Windows Pre-AD Workstation Setup Report (SIMULATED)"
            "Version: $ScriptVersion"
            "Computer: SIMULATED-HOST"
            "Form Factor (detected): $machineType"
            "Transcript: $transcriptPath"
            ""
            "=== RESULTS (simulated) ==="
            "$($script:Results | Format-Table -AutoSize | Out-String)"
            ""
            "Next step: Review above. (No changes were made.)"
        )
    } else {
        $reportPath = Join-Path $env:TEMP "WindowsSetupReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $reportLines = @(
            "Windows Pre-AD Workstation Setup Report"
            "Version: $ScriptVersion"
            "Timestamp: $(Get-Date -Format o)"
            "Computer: $env:COMPUTERNAME"
            "OS: $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
            "Manufacturer/Model: $((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer) / $((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Model)"
            "Form Factor (detected): $machineType"
            "PartOfDomain: $((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain)"
            "Transcript: $transcriptPath"
            ""
            "=== RESULTS ==="
            "$($script:Results | Format-Table -AutoSize | Out-String)"
            ""
            "Next step: Review above. Workstation is ready for Active Directory join (unless Failed entries above)."
        )
    }
    $reportContent = $reportLines -join "`r`n"

    if (-not $Simulate) {
        try {
            $reportContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force
        } catch {
            Write-Warning "Failed to write persistent report to $reportPath (disk full or permissions?). Summary was still shown on console."
        }
    } else {
        # In simulation, just show it on screen instead of writing file
        Write-Host "(Simulation: report would be written to $reportPath)"
    }

    Write-Host "Detailed log   : $transcriptPath"
    if (-not $Simulate) {
        Write-Host "Report artifact: $reportPath"
    }
    Write-Host "Review the summary above. The workstation is now ready for Active Directory join." -ForegroundColor Cyan

    if ($PauseOnExit -and -not $Simulate) {
        Read-Host "`nPress Enter to close this window..."
    }

    # Exit code policy
    $failedCount = ($script:Results | Where-Object Status -eq 'Failed').Count
    if ($failedCount -gt 0) {
        Write-Warning "$failedCount step(s) failed. See report for details."
        exit 1
    } else {
        exit 0
    }
}

#endregion
