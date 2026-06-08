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

[CmdletBinding()]
param(
    [string]$LocalAdminPassword,
    [string]$PasswordFile,   # Path to ACL-restricted temp file (plain or base64). Preferred for wrappers.
    [switch]$AssumeDesktop,
    [switch]$AssumeLaptop,
    [switch]$Simulate   # Run in simulation mode (no real system changes, useful for testing on non-Windows or dry-runs)
)

$ScriptVersion = '0.1.0'
$ScriptCommit = 'b821220'   # Update this when you commit changes
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
    # TODO (PR2): real implementation + idempotency check
    Add-Result 'UAC' 'Placeholder' 'Not yet implemented'
    Write-Success "UAC set to never notify (placeholder)"
}

function Set-DateTimeAutomatic {
    Write-Step "Configuring Date and Time (automatic + location-based)"
    # TODO (PR2)
    Add-Result 'DateTime' 'Placeholder' 'Not yet implemented'
    Write-Success "Date and Time configured (placeholder)"
}

function Set-PowerPlan {
    param([string]$MachineType)
    Write-Step "Configuring Power Plan for $MachineType"
    # TODO (PR2): real powercfg /change + correct matrix
    Add-Result 'PowerPlan' 'Placeholder' "MachineType=$MachineType (not yet implemented)"
    Write-Success "Power plan updated (placeholder)"
}

function Set-LocalAdministrator {
    Write-Step "Configuring Local Administrator Account"

    $admin = Get-BuiltInAdministrator
    if (-not $admin) {
        Add-Result 'LocalAdmin' 'Failed' 'Built-in Administrator account not found (even by SID)'
        Write-Warning "Could not locate built-in Administrator account by SID or name."
        return
    }

    # Password source handling (PR1 wiring for $PasswordFile / base64 / prompt)
    $plain = $null
    if (-not $Simulate -and $PasswordFile -and (Test-Path $PasswordFile)) {
        try {
            $content = Get-Content -Path $PasswordFile -Raw -ErrorAction Stop
            try {
                $bytes = [Convert]::FromBase64String($content.Trim())
                $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
            } catch { $plain = $content.Trim() }
        } finally {
            Remove-Item -Path $PasswordFile -Force -ErrorAction SilentlyContinue
        }
    } elseif (-not $Simulate -and $LocalAdminPassword) {
        try {
            $bytes = [Convert]::FromBase64String($LocalAdminPassword)
            $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
        } catch { $plain = $LocalAdminPassword }
    } elseif ($Simulate) {
        # In simulation we never actually read a file or prompt
        $plain = $null
    }

    # Idempotency guard (skip prompt entirely on re-runs if already good)
    if ($admin.Enabled -and $admin.PasswordNeverExpires -and -not $plain) {
        Write-Skip "Local Administrator ($($admin.Name)) already enabled with PasswordNeverExpires=true"
        Add-Result 'LocalAdmin' 'Skipped' 'Account already in desired state'
        return
    }

    if ($plain) {
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    } else {
        $secure = Read-Host -Prompt "Enter password for local Administrator account" -AsSecureString
    }

    # TODO (PR2): actual account changes using SID where possible
    # if (-not $admin.Enabled) { Enable-LocalUser -SID $admin.SID }
    # Set-LocalUser -SID $admin.SID -Password $secure -PasswordNeverExpires $true

    Add-Result 'LocalAdmin' 'Placeholder' "Password handling wired (SID helper + sources + guard). Real Enable/Set in PR2."
    Write-Success "Local Administrator (password handling demonstrated)"
}

function Enable-RemoteDesktop {
    Write-Step "Enabling Remote Desktop"
    # TODO (PR2)
    Add-Result 'RemoteDesktop' 'Placeholder' 'Not yet implemented'
    Write-Success "Remote Desktop enabled (placeholder)"
}

function Uninstall-DellOptimizer {
    Write-Step "Checking for and uninstalling Dell Optimizer"
    # TODO (PR3)
    Add-Result 'DellOptimizer' 'Placeholder' 'Not yet implemented'
    Write-Success "Dell Optimizer handled (placeholder)"
}

function Uninstall-NonEnglishOffice {
    Write-Step "Removing non-English Office 365 installations"
    # TODO (PR3)
    Add-Result 'OfficeLanguages' 'Placeholder' 'Not yet implemented'
    Write-Success "Non-English Office versions removed (placeholder)"
}

function Install-Chrome {
    Write-Step "Installing Google Chrome"
    # TODO (PR4)
    Add-Result 'Chrome' 'Placeholder' 'Not yet implemented'
    Write-Success "Chrome installed (placeholder)"
}

function Install-AdobeAcrobatReader {
    Write-Step "Installing Adobe Acrobat Reader"
    # TODO (PR4)
    Add-Result 'AcrobatReader' 'Placeholder' 'Not yet implemented'
    Write-Success "Adobe Acrobat Reader installed (placeholder)"
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
    } else {
        $reportPath = Join-Path $env:TEMP "WindowsSetupReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    }

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
