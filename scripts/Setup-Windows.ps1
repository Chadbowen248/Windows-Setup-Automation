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

$ScriptVersion = '0.1.1'
$ScriptCommit = 'bf33bbc'   # Update this when you commit changes
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
        [ValidateSet('Success','Skipped','Failed','Warning','Simulated')][string]$Status,
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

# Robust helper for cmd.exe /c execution. Replaces every bare "cmd /c ..." in Dell/Office
# (and considered for winget paths). Uses Start-Process 'cmd.exe' /c ... -Wait -PassThru
# so we get reliable real ExitCode from .ExitCode (bare cmd /c in PS does not always
# propagate $LASTEXITCODE correctly under elevation, transcripts, or certain PS hosts
# on real hardware). This is the root cause of false "Success"/"handled" reports when
# the actual uninstall command did nothing observable.
# Smallest single helper, pure ASCII, follows existing indent/style, placed with
# other foundation helpers. All Simulate/early-Skip paths untouched.
function Invoke-Cmd {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return 1 }
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $CommandLine -Wait -PassThru -WindowStyle Hidden
    if (-not $p) { return 1 }
    return $p.ExitCode
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
    if ($Simulate) {
        Add-Result 'LocalAdmin' 'Simulated' 'Local Administrator configured (simulated)'
        Write-Success "Local Administrator (simulated)"
        return
    }

    $admin = Get-BuiltInAdministrator
    if (-not $admin) {
        Add-Result 'LocalAdmin' 'Failed' 'Built-in Administrator account not found (even by SID)'
        Write-Warning "Could not locate built-in Administrator account by SID or name."
        return
    }

    # Auto-discover pw.txt in the same directory as the script (for simple USB/drop-and-run use).
    # This is a fallback only. Explicit -LocalAdminPassword or -PasswordFile take precedence.
    # The pw.txt file may contain comments (lines starting with #); the first non-empty, non-comment line is used as the plain-text password.
    if (-not $LocalAdminPassword -and -not $PasswordFile) {
        $pwFile = Join-Path $PSScriptRoot 'pw.txt'
        if (Test-Path $pwFile -PathType Leaf) {
            $lines = Get-Content -Path $pwFile -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -and -not $trimmed.StartsWith('#')) {
                    $LocalAdminPassword = $trimmed
                    Write-Host "Using password from pw.txt (same directory as script)" -ForegroundColor Yellow
                    break
                }
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
            # Smart detection: try base64 (for internal elevation forwarding), verify by re-encoding.
            # If it matches re-encode or decode fails, treat as plain text (from direct param or pw.txt).
            try {
                $bytes = [Convert]::FromBase64String($LocalAdminPassword)
                $decoded = [System.Text.Encoding]::Unicode.GetString($bytes)
                $reencoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($decoded))
                if ($reencoded -eq $LocalAdminPassword) {
                    $plain = $decoded
                } else {
                    $plain = $LocalAdminPassword
                }
            } catch {
                $plain = $LocalAdminPassword
            }
        } else {
            $plain = $null
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
    # Stop services first (common blocker per community reports)
    Get-Service -Name '*DellOptimizer*','*Dell*Optimizer*' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue

    # Pre-discovery for diagnostics (what the tech will see in report)
    $foundPkgs = @(Get-Package -Name '*Dell*Optimizer*','*Optimizer*Service*' -ErrorAction SilentlyContinue)
    $foundReg = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Get-ItemProperty | Where-Object { ($_.DisplayName -like '*Dell*Optimizer*' -or $_.DisplayName -like '*Optimizer*Service*') -and ($_.UninstallString -or $_.QuietUninstallString) })
    # Broaden exe discovery (InstallShield info can live under PF or PF(x86))
    $dellExe = $null
    foreach ($base in @('C:\Program Files (x86)\InstallShield Installation Information', 'C:\Program Files\InstallShield Installation Information')) {
        $dellExe = Get-ChildItem $base -Recurse -Filter '*DellOptimizer*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dellExe) { break }
    }
    $preList = @()
    if ($foundPkgs) { $preList += ($foundPkgs | ForEach-Object { $_.Name }) }
    if ($foundReg)  { $preList += ($foundReg | ForEach-Object { $_.DisplayName }) }
    if ($dellExe)   { $preList += "exe:$($dellExe.FullName)" }
    if ($preList) {
        Write-Host "    Found Dell bloat candidates: $($preList -join ' | ')" -ForegroundColor Yellow
    }

    $actionTaken = $false
    $details = @()
    # Prefer official Dell uninstaller if we can find it (Dell docs: DellOptimizer.exe /remove  or variants with -silent)
    if ($dellExe) {
        $cmd = "`"$($dellExe.FullName)`" /remove /silent"
        $ec = Invoke-Cmd $cmd
        $actionTaken = $true
        $details += "Ran exe: $cmd (exit: $ec)"
    }
    # Try Get-Package (multiple name patterns)
    $pkg = Get-Package -Name '*Dell*Optimizer*','*Optimizer*Service*' -ErrorAction SilentlyContinue
    if ($pkg) {
        $pkg | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null
        $actionTaken = $true
        $details += "Uninstalled via Get-Package"
    }
    # Fallback / additional: registry uninstall strings (both hives)
    $uninst = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Get-ItemProperty | Where-Object { ($_.DisplayName -like '*Dell*Optimizer*' -or $_.DisplayName -like '*Optimizer*Service*') -and ($_.UninstallString -or $_.QuietUninstallString) }
    if ($uninst) {
        foreach ($u in $uninst) {
            $cmd = if ($u.QuietUninstallString -and $u.QuietUninstallString.Trim()) { $u.QuietUninstallString } else { $u.UninstallString }
            if ($cmd -match 'msiexec') {
                $cmd += ' /qn /norestart'
            } else {
                $cmd += ' /remove /silent'
            }
            $ec = Invoke-Cmd $cmd
            $actionTaken = $true
            $details += "Ran reg: $cmd (exit: $ec)"
        }
    }

    # Verify after actions - combined signals (Get-Package is not always authoritative for all Dell installers)
    $stillPkg = Get-Package -Name '*Dell*Optimizer*','*Optimizer*Service*' -ErrorAction SilentlyContinue
    $stillReg = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        Get-ItemProperty | Where-Object { ($_.DisplayName -like '*Dell*Optimizer*' -or $_.DisplayName -like '*Optimizer*Service*') -and ($_.UninstallString -or $_.QuietUninstallString) }
    # Broaden still-exe check too (same folders)
    $stillExe = $null
    foreach ($base in @('C:\Program Files (x86)\InstallShield Installation Information', 'C:\Program Files\InstallShield Installation Information')) {
        $stillExe = Get-ChildItem $base -Recurse -Filter '*DellOptimizer*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($stillExe) { break }
    }
    $stillPresent = ($stillPkg -or $stillReg -or $stillExe)

    if (-not $stillPresent) {
        if ($actionTaken) {
            Add-Result 'DellOptimizer' 'Success' "Dell Optimizer uninstalled. Pre: $($preList -join ' | '). Details: $($details -join '; ')"
            Write-Success "Dell Optimizer uninstalled"
        } else {
            Write-Skip "Dell Optimizer not present"
            Add-Result 'DellOptimizer' 'Skipped' 'Not present'
        }
    } else {
        Add-Result 'DellOptimizer' 'Failed' "Uninstall attempted but Optimizer still detected after. Pre: $($preList -join ' | '). Tried: $($details -join '; '). Manual removal via Apps & features or Dell support may be needed."
        Write-Warning "Dell Optimizer uninstall attempted but still present - check report for details."
    }
}

function Uninstall-NonEnglishOffice {
    Write-Step "Removing non-English Microsoft 365 / Office / OneNote language packs"
    if ($Simulate) {
        Add-Result 'OfficeLanguages' 'Simulated' 'Non-English Office removed (simulated)'
        Write-Success "Non-English Office versions removed (simulated)"
        return
    }
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

    # Research note (Get Help path):
    # Using Get Help > Uninstall (Office troubleshooter) launches the SaRA / GetHelpCmd.exe -S OfficeScrubScenario.
    # That performs a comprehensive full removal of detected Office (services, files, registry, etc.).
    # It is NOT language-selective by default. To mimic "that level of clean" while KEEPING en-us:
    #   - Preferred supported way: Office Deployment Tool (ODT) + config.xml with <Remove> specifying only the
    #     unwanted <Language ID="fr-fr" /> etc. (requires small official download of setup.exe).
    #   - This in-box function does the closest zero-download approximation: target the per-language ARP entries
    #     that appear on OEM/Dell preloads (e.g. "Microsoft 365 - es-es", "Microsoft 365 - fr-fr", "Microsoft 365 - pt-br",
    #     and "Microsoft OneNote - fr-fr" etc.) by directly driving the same OfficeClickToRun.exe mechanism the UI
    #     and Get Help per-item uninstalls use.
    #   - If this is insufficient on a given image, the final report will say Failed and recommend the Get Help
    #     troubleshooter (full scrub via OfficeScrubScenario) or ODT remove-languages. The en-us base should remain
    #     untouched because we explicitly exclude entries containing en-us.

    # Fidelity to the Get Help / Apps & features removal of the exact language bloat entries:
    # - Kill Office/ClickToRun processes (they hold locks).
    # - Stop ClickToRun* services.
    # - For "Microsoft 365 - xx-xx" (and "Microsoft OneNote - xx-xx", Localization Component) ARP entries:
    #   extract productstoremove from the machine's own registration (this captures the exact ..._xx-xx_x-none
    #   etc. for this image), then invoke the canonical OfficeClickToRun.exe directly with scenario=install ...
    #   productstoremove=... displaylevel=false forceappshutdown=true . This is the invocation pattern used by
    #   successful community scripts and what the Get Help flow ultimately exercises for those visible per-language
    #   entries (including separate OneNote languages).
    # - Use direct Start-Process (not cmd /c string) for the C2R exe so we get reliable EC and avoid quoting issues.
    # - Prefer QuietUninstallString. Fallback to other uninstallers via Invoke-Cmd for non-C2R.
    # - Always re-scan after. Success requires zero remaining non-en matches + good ecs.
    # - en-us exclusion is absolute (multiple guards + early filter). Leaves English/core functional.

    # Broad match for C2R language entries and localization bloat.
    # Covers the exact user-reported forms: "Microsoft 365 - es-es", "Microsoft 365 - fr-fr", "Microsoft 365 - pt-br",
    # "Microsoft OneNote es-es", "Microsoft OneNote - fr-fr", "Microsoft OneNote - pt-br"
    # plus " - fr-fr", "(fr-fr)", Language Packs, and "Office 16 Click-to-Run Localization Component" (non-en).
    # en-us/English core exclusion is absolute (never remove).
    $c2r = Get-ChildItem $keys -ErrorAction SilentlyContinue | Get-ItemProperty |
        Where-Object {
            $name = $_.DisplayName
            if (-not $name) { return $false }
            if ($name -match 'en-us') { return $false }
            $isOffice = ($name -match 'Microsoft (365|Office|M365|Office 16|Office Language Pack|Click-to-Run Localization|OneNote)')
            # Any locale tag that is not en-us. Handles exact forms user sees in appwiz.cpl.
            $hasNonEnLocale = ($name -match 'Microsoft (365|OneNote) - [a-z]{2}-[a-z]{2}' -or
                               $name -match ' - [a-z]{2}-[a-z]{2}' -or
                               $name -match '\([a-z]{2}-[a-z]{2}\)' -or
                               $name -match ' [a-z]{2}-[a-z]{2}(\s|$|\))') -and ($name -notmatch 'en-us')
            # Also catch bare localization components even without obvious locale in the name (common OEM bloat)
            $isLocalizationBloat = ($name -like '*Click-to-Run Localization Component*') -and ($name -notmatch 'en-us')
            ($isOffice -and ($hasNonEnLocale -or $isLocalizationBloat)) -and (($_.UninstallString -and $_.UninstallString.Trim()) -or ($_.QuietUninstallString -and $_.QuietUninstallString.Trim()))
        }
    if (-not $c2r) {
        Write-Skip "No non-English Office/OneNote language packs or localization bloat found"
        Add-Result 'OfficeLanguages' 'Skipped' 'None found'
        return
    }

    # Log exactly what we are targeting (critical visibility for the technician and for debugging "still present")
    $targets = $c2r | ForEach-Object { $_.DisplayName }
    Write-Host "    Targeting non-English Office/OneNote entries: $($targets -join ' | ')" -ForegroundColor Yellow

    # Kill common Office/ClickToRun processes first (they frequently block C2R language removals).
    # This step is part of what makes Get Help / manual per-entry uninstalls succeed where naive string runs fail.
    $officeProcs = @(
        'winword','excel','powerpnt','outlook','onenote','mspub','msaccess',
        'lync','teams','skype','communicator',
        'OfficeClickToRun','ClickToRun','AppVShNotify','integratedoffice','firstrun'
    )
    foreach ($p in $officeProcs) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Best-effort stop of ClickToRun services (common blockers for C2R lang uninstalls).
    Get-Service -Name 'ClickToRunSvc','*ClickToRun*','*OfficeClickToRun*' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $removed = @()
    $attempted = @()
    $ecs = @()

    # Resolve the Click-to-Run orchestrator (the exe that actually removes the "Microsoft 365 - xx-xx" entries).
    # Normally under 64-bit Program Files even on x64 Windows. Fall back to (x86) for 32-bit Office images.
    $c2rExe = Join-Path ${env:ProgramFiles} 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
    if (-not (Test-Path -LiteralPath $c2rExe -PathType Leaf)) {
        $c2rExe86 = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe'
        if (Test-Path -LiteralPath $c2rExe86 -PathType Leaf) { $c2rExe = $c2rExe86 }
    }

    foreach ($entry in $c2r) {
        $orig = if ($entry.QuietUninstallString -and $entry.QuietUninstallString.Trim()) { $entry.QuietUninstallString } else { $entry.UninstallString }
        $ec = 1
        $effective = $orig

        if ($orig -match 'OfficeClickToRun\.exe') {
            # Replicate the exact mechanism used for the visible "Microsoft 365 - xx-xx" entries.
            # Extract the productstoremove= value that the registration recorded for this language (e.g. O365HomePremRetail.16_fr-fr_x-none).
            # Then drive the canonical exe directly (more reliable than cmd /c of the raw ARP string).
            $prodRemove = $null
            if ($orig -match 'productstoremove=([^\s"]+)') {
                $prodRemove = $matches[1]
            }
            if (-not $prodRemove) {
                # Fallback: some registrations embed the culture directly; try to synthesize a minimal one.
                # This is rare for the " - xx-xx" entries.
                $prodRemove = 'O365HomePremRetail.16'
            }

            $argLine = "scenario=install scenariosubtype=ARP sourcetype=None productstoremove=$prodRemove displaylevel=false forceappshutdown=true"
            # If the original had a culture= token, keep it for fidelity (append if not already present in our minimal line).
            if ($orig -match 'culture=([^\s"]+)') {
                $cult = $matches[1]
                if ($argLine -notmatch 'culture=') { $argLine += " culture=$cult" }
            }
            if ($orig -match 'version\.16=([^\s"]+)') {
                $ver = $matches[1]
                if ($argLine -notmatch 'version\.16=') { $argLine += " version.16=$ver" }
            }

            $effective = "$c2rExe $argLine"
            $attempted += $effective

            try {
                $p = Start-Process -FilePath $c2rExe -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                $ec = if ($p) { $p.ExitCode } else { 1 }
            } catch {
                $ec = 1
            }
        } elseif ($orig -match 'msiexec') {
            $effective = ($orig + ' /qn /norestart').Trim()
            $attempted += $effective
            $ec = Invoke-Cmd $effective
        } else {
            $effective = ($orig + ' /quiet /norestart').Trim()
            $attempted += $effective
            $ec = Invoke-Cmd $effective
        }

        $ecs += $ec
        if ($ec -eq 0) {
            $removed += $entry.DisplayName
        }
    }

    Start-Sleep -Seconds 3
    # One more service stop + process kill in case the uninstallers restarted anything.
    Get-Service -Name 'ClickToRunSvc','*ClickToRun*','*OfficeClickToRun*' -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    foreach ($p in $officeProcs) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Verify: always re-scan with the identical non-en filter.
    # Success only when post-re-scan shows no more matches AND the commands we ran reported ec==0.
    # This matches the "truthful verification" contract added for Get Help fidelity.
    $c2rAfter = Get-ChildItem $keys -ErrorAction SilentlyContinue | Get-ItemProperty |
        Where-Object {
            $name = $_.DisplayName
            if (-not $name) { return $false }
            if ($name -match 'en-us') { return $false }
            $isOffice = ($name -match 'Microsoft (365|Office|M365|Office 16|Office Language Pack|Click-to-Run Localization|OneNote)')
            $hasNonEnLocale = ($name -match 'Microsoft (365|OneNote) - [a-z]{2}-[a-z]{2}' -or
                               $name -match ' - [a-z]{2}-[a-z]{2}' -or
                               $name -match '\([a-z]{2}-[a-z]{2}\)' -or
                               $name -match ' [a-z]{2}-[a-z]{2}(\s|$|\))') -and ($name -notmatch 'en-us')
            $isLocalizationBloat = ($name -like '*Click-to-Run Localization Component*') -and ($name -notmatch 'en-us')
            ($isOffice -and ($hasNonEnLocale -or $isLocalizationBloat)) -and (($_.UninstallString -and $_.UninstallString.Trim()) -or ($_.QuietUninstallString -and $_.QuietUninstallString.Trim()))
        }

    $allEcsGood = ($ecs.Count -eq 0) -or (-not ($ecs -ne 0))
    if (-not $c2rAfter -and $allEcsGood) {
        Add-Result 'OfficeLanguages' 'Success' "Removed non-English Office/OneNote entries (C2R direct + registry). Targeted: $($targets -join '; '). Removed: $($removed -join '; '). Attempted: $($attempted -join '; ')"
        Write-Success "Non-English Office/OneNote versions removed (direct C2R invocation matching Get Help per-language behavior; en-us preserved)"
    } else {
        $remaining = $c2rAfter | ForEach-Object { $_.DisplayName }
        $ecSummary = if ($ecs) { "ecs: $($ecs -join ','). " } else { "" }
        Add-Result 'OfficeLanguages' 'Failed' "${ecSummary}Some non-English Office/OneNote may remain. Remaining: $($remaining -join ', '). Targeted before: $($targets -join '; '). Tried: $($attempted -join '; '). Use Get Help app (Office uninstall troubleshooter) for full scrub or ODT for explicit language remove while preserving en-us."
        Write-Warning "Office language removal attempted but some may remain - check report for details and consider Get Help or ODT."
    }
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
    # Best-effort source update (non-fatal). Use assignment (not | Out-Null) then LASTEXITCODE.
    $null = winget source update --accept-source-agreements 2>&1
    $srcExit = $LASTEXITCODE
    # Install line followed by real $LASTEXITCODE capture + re-query presence for truthful Success.
    # Never unconditional Success after | Out-Null. Only Success + Write-Success when package
    # actually present afterward (re-query is the contract). $installExit checked (considered).
    $installOutput = winget install --id Google.Chrome -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
    $installExit = $LASTEXITCODE
    # Post-action verification: the only reliable signal is actual presence after
    $presentAfter = winget list --id Google.Chrome --accept-source-agreements 2>$null
    if ($presentAfter -match 'Google.Chrome') {
        Add-Result 'Chrome' 'Success' "Google Chrome installed (srcExit: $srcExit, installExit: $installExit)"
        Write-Success "Chrome installed"
    } else {
        Add-Result 'Chrome' 'Failed' "winget install attempted but Chrome not detected after. Exit: $installExit. Output tail: $(($installOutput -split "`n" | Select-Object -Last 5) -join "`n")"
        Write-Warning "Chrome install may have failed - see report details (winget source, network, or policy can interfere on fresh images)."
    }
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
    # Best-effort source update (non-fatal). Use assignment (not | Out-Null) then LASTEXITCODE.
    $null = winget source update --accept-source-agreements 2>&1
    $srcExit = $LASTEXITCODE
    # Install line followed by real $LASTEXITCODE capture + re-query presence for truthful Success.
    # Never unconditional Success after | Out-Null. Only Success + Write-Success when package
    # actually present afterward (re-query is the contract). $installExit checked (considered).
    $installOutput = winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
    $installExit = $LASTEXITCODE
    $presentAfter = winget list --id $id --accept-source-agreements 2>$null
    if ($presentAfter -match $id) {
        Add-Result 'AcrobatReader' 'Success' "Adobe Acrobat Reader installed (srcExit: $srcExit, installExit: $installExit)"
        Write-Success "Adobe Acrobat Reader installed"
    } else {
        Add-Result 'AcrobatReader' 'Failed' "winget install attempted but Reader not detected after. Exit: $installExit. Output tail: $(($installOutput -split "`n" | Select-Object -Last 5) -join "`n")"
        Write-Warning "Acrobat Reader install may have failed - see report details."
    }
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

    # Execute the 9 steps (each records via Add-Result). Wrapped individually in
    # try/catch so one step's failure (e.g. Office uninstall) never skips later
    # steps (installs) or leaves the results report incomplete. Each catch adds
    # a truthful Failed result. Internal Simulate guards + early Skips preserved.
    try { Set-UACNeverNotify } catch { Add-Result 'UAC' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Set-DateTimeAutomatic } catch { Add-Result 'DateTime' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Set-PowerPlan -MachineType $machineType } catch { Add-Result 'PowerPlan' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Set-LocalAdministrator } catch { Add-Result 'LocalAdmin' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Enable-RemoteDesktop } catch { Add-Result 'RemoteDesktop' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Uninstall-DellOptimizer } catch { Add-Result 'DellOptimizer' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Uninstall-NonEnglishOffice } catch { Add-Result 'OfficeLanguages' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Install-Chrome } catch { Add-Result 'Chrome' 'Failed' "Step threw: $($_.Exception.Message)" }
    try { Install-AdobeAcrobatReader } catch { Add-Result 'AcrobatReader' 'Failed' "Step threw: $($_.Exception.Message)" }

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
