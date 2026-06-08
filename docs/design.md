# Design Document: Windows-Setup-Automation

**Project**: Windows-Setup-Automation  
**Location**: `Projects/Windows-Setup-Automation` (relative to workspace root `/Users/pinche`)  
**Date**: 2026-06-07  
**Author**: Systems Architect (Grok Build subagent)  
**Status**: Design complete; ready for incremental implementation

---

## Overview

This design specifies a zero-friction automation tool for standardizing the pre-Active Directory join configuration of brand-new or reset Windows Pro workstations (primary target: Windows 11 Pro). 

The primary deliverable is a single, self-contained `Setup-Windows.ps1` PowerShell script that a technician can obtain (via share, USB, etc.), launch, answer the minimal necessary prompts (chiefly the desired local Administrator password), and walk away from. The script handles elevation automatically, auto-detects hardware form factor, applies all required settings and software installs with clear progress feedback, and produces a comprehensive final summary/report. A companion `.exe` (built from the script) is supported as a desirable secondary artifact for environments preferring a single executable with embedded admin manifest.

All steps are designed to be as idempotent and safely re-runnable as practical. The tool relies exclusively on built-in Windows facilities (PowerShell 5.1+, CIM/WMI, `powercfg`, registry, `winget`, netsh/net commands, LocalAccounts cmdlets) plus `winget` for the two software packages. No pre-installation of any tooling is required on the target machine.

The current skeleton at `scripts/Setup-Windows.ps1` (with elevation helper, `Write-Step` family, placeholder functions for all 9 steps, basic main flow, and TODOs) serves as the starting point; the design evolves and completes it without unnecessary restructuring.

## Background

Technicians currently perform a repetitive, error-prone sequence of ~9 manual steps on every Windows Pro workstation before domain join (detailed in `docs/requirements.md` and the project `README.md`). 

The skeleton script already captures the high-level structure and intent:
- Param block supporting `-LocalAdminPassword`, `-AssumeDesktop`, `-AssumeLaptop`.
- `Test-Admin` + `Request-Elevation` (with basic arg forwarding).
- `Write-Step` / `Write-Success` / `Write-Skip` helpers.
- Placeholder functions for UAC, DateTime, PowerPlan, LocalAdmin, RemoteDesktop, DellOptimizer, non-English Office, Chrome, and Acrobat Reader.
- Sequential main execution with a stub summary.

Current open questions from requirements (exact Win versions, self-elev vs. manual, delivery mechanism, logging depth, additional steps) are addressed here with concrete recommendations, while preserving a dedicated "Open Questions" section for any remaining items requiring user input.

The design prioritizes the user's latest explicit decisions: single `.ps1` primary, self-elevation with param passthrough, automatic laptop/desktop detection (no manual switches preferred), `winget` preference for installs, minimal questions, and strong final confirmation/summary.

## Goals & Non-Goals

### Goals (Must Have)
- **Zero operator friction**: Trivial launch on stock Windows 11 Pro (or 10 Pro) with no pre-requisites beyond what ships with the OS. Single `.ps1` (or built `.exe`) is the ideal.
- Interactive but low-question experience: clear prompts (primarily local admin password), visible progress via `==> Step` style + success/skip indicators, and "set it and forget it" execution.
- Automatic self-elevation with reliable forwarding of parameters (including the local admin password) and switches.
- Automatic, robust laptop vs. desktop detection (WMI/CIM-driven) to select the correct power plan; override switches retained only for diagnostics/edge cases.
- Prefer `winget` (with full silent + agreement flags) for Chrome (`Google.Chrome`) and Adobe Acrobat Reader (`Adobe.Acrobat.Reader.64-bit`).
- Idempotency / safe re-runnability for configuration steps where feasible (state checks before mutate).
- Comprehensive final summary/report (what changed, what was skipped, what failed) plus persistent logging.
- All steps isolated so one failure does not abort the entire run.
- Support for manufacturer-specific logic (Dell Optimizer) handled gracefully via detection (no hard failure on non-Dell).

### Nice-to-Haves (Addressed in Design but Lower Priority)
- File-based logging (transcript + structured report) + on-screen summary.
- Ability to evolve toward more automated/answer-file style (e.g., future `-Unattended` + password file).
- Skip/detect already-correct state for *all* steps.
- Distribution artifacts that preserve zero friction (e.g., optional `.cmd` launcher).

### Non-Goals (Out of Scope for Initial Design / v1)
- A full GUI (WPF/WinForms or otherwise) — rejected if it introduces any install/runtime friction or dependencies. CLI with colored output is sufficient and preferred.
- Domain join or post-join steps.
- Support for non-Pro editions or non-workstation SKUs.
- Bundling or downloading the Office Deployment Tool (ODT) as a hard requirement (registry-based Office language removal is primary).
- Complex custom power plans beyond the exact timeout requirements.
- Remote execution, Intune packaging, or enterprise management integration (future possible).
- Unit tests / Pester suite in v1 (manual verification + later PR).
- Changing the built-in Administrator account name or creating a *new* local admin.

### Success Criteria
A technician can copy/run the tool, answer 1-2 prompts, walk away, and return to a standardized machine with a clear report, ready for AD join. Re-running the tool is safe and mostly a no-op on an already-configured machine.

## Proposed Design

### High-Level Architecture & Execution Flow

The tool is a single PowerShell script (`scripts/Setup-Windows.ps1`) executed under the logged-on user's context (typically a local tech account). It is deliberately monolithic for zero-friction distribution—no modules, no supporting files required at runtime (except an optional tiny `.cmd` wrapper and the future built `.exe`).

Key components:
- **Entry / Param handling + elevation gate**.
- **Infrastructure**: Logging (transcript), results collection, machine metadata, version banner.
- **Detection**: Hardware form factor (laptop/desktop).
- **Step functions**: One per requirement (9 total), each with its own idempotency guard, implementation, and result recording.
- **Summary / reporting**: Structured output + log finalization.

```mermaid
flowchart TD
    A[Technician launches Setup-Windows.ps1<br/>or .cmd or built .exe] --> B1[Print minimal title banner]
    B1 --> B{Test-Admin?}
    B -->|No| C[Build arg list (base64 pw if supplied)<br/>-NoProfile -ExecutionPolicy Bypass -File ...<br/>+ forwarded params/switches]
    C --> D[Start-Process powershell.exe -Verb RunAs]
    D --> E[Print "Relaunching..."<br/>exit (non-elev instance ends)]
    B -->|Yes| F[Start-Transcript -IncludeInvocationHeader<br/>Print full machine-info banner (CIM + version)<br/>only in elevated context]
    F --> G[Determine MachineType<br/>Auto-detect via CIM (preferred)<br/>or honor -Assume* or prompt fallback]
    G --> H[Execute steps in fixed order<br/>each wrapped in try/catch for isolation]
    H --> I1[1. Set-UACNeverNotify<br/>registry check + mutate]
    H --> I2[2. Set-DateTimeAutomatic<br/>w32time + tzautoupdate + location consent]
    H --> I3[3. Set-PowerPlan<br/>powercfg /change for AC/DC timeouts]
    H --> I4[4. Set-LocalAdministrator<br/>state guard first (skip prompt if already good);<br/>then prompt/convert (base64 decode) pw, Enable, Set -PasswordNeverExpires]
    H --> I5[5. Enable-RemoteDesktop<br/>fDenyTSConnections + NLA + firewall + service]
    H --> I6[6. Uninstall-DellOptimizer<br/>Manufacturer match + service stop + uninstall string / Get-Package]
    H --> I7[7. Uninstall-NonEnglishOffice<br/>Registry scan for lang-specific DisplayNames + silent uninstall]
    H --> I8[8. Install-Chrome<br/>winget list check + winget install --id Google.Chrome + accepts + --silent]
    H --> I9[9. Install-AdobeAcrobatReader<br/>winget ... --id Adobe.Acrobat.Reader.64-bit]
    I9 --> J[try/finally: Stop-Transcript; always emit table + write persistent report]
    J --> K[Exit 0 (or 1 if any Failed results)]
```

Results are accumulated in a script-scoped list (`$script:Results`) of objects `{ Step, Status, Details, Timestamp? }`. Every step function calls `Add-Result` (or equivalent) before returning. The final report uses `Format-Table` (and optionally `Export-Csv` / `Out-File` for a persistent artifact).

The script version (`$ScriptVersion = '0.1.0'`) is embedded and printed in the banner.

### Self-Elevation Pattern (Critical Technical Challenge)

The skeleton's `Request-Elevation` is the foundation and will be hardened.

```powershell
# Top-level param block (add $PasswordFile for the recommended temp-file handoff path)
param(
    [string]$LocalAdminPassword,
    [string]$PasswordFile,   # Path to ACL-restricted temp file containing pw (plain or base64-encoded). Preferred for wrappers to avoid secret in argv/transcript header. Caller creates/deletes; script reads + cleans in finally.
    [switch]$AssumeDesktop,
    [switch]$AssumeLaptop
)

function Test-Admin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    if (Test-Admin) { return }

    Write-Warning "Administrative privileges required. Relaunching as Administrator..."
    Write-Host "  (You may see a UAC prompt.)" -ForegroundColor Yellow

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`""
    )

    # Forward non-sensitive switches
    if ($AssumeDesktop) { $argList += '-AssumeDesktop' }
    if ($AssumeLaptop)  { $argList += '-AssumeLaptop' }

    # Password passthrough (see Password forwarding specifics + Security).
    # Two supported secure paths for the elevated instance:
    # 1. $PasswordFile (preferred for wrappers/unattended to keep secret off argv and transcript header): the *caller* creates an ACL-restricted temp file containing the pw (plain or base64), passes the *path* only. Script reads + deletes in finally.
    # 2. $LocalAdminPassword (base64 encoded for simple cases): direct value (still visible briefly in argv/transcript for the elevated process).
    if ($PasswordFile) {
        $argList += '-PasswordFile', "`"$PasswordFile`""
    } elseif ($LocalAdminPassword) {
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($LocalAdminPassword)
        $encoded = [Convert]::ToBase64String($bytes)
        $argList += '-LocalAdminPassword', $encoded
    }

    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}
```

**Invocation context handling and authoritative main() sketch (resolves banner/transcript ordering)**:
- The *initial* banner (title lines only) prints in the launching (possibly non-elev) context for immediate user feedback.
- `Request-Elevation` is called immediately after; it exits the non-elev instance if it relaunches.
- Only the elevated path proceeds to `Start-Transcript -IncludeInvocationHeader`, full machine-info banner (CIM + version + domain status), detection, steps, and the try/finally-guaranteed summary + report.
- Light duplication of the title banner is accepted (it is harmless and gives continuity in the new console after UAC). Full machine facts and results live only in the elevated transcript/report.
- Authoritative top-of-main code (drop-in for PR1; evolves the skeleton exactly):

```powershell
# top level (runs in both contexts)
Write-Host "Windows Workstation Pre-AD Setup" -ForegroundColor Magenta
Write-Host "=================================" -ForegroundColor Magenta

Request-Elevation   # if not admin: builds argList (with -PasswordFile path if supplied, else base64 -LocalAdminPassword), Start-Process -Verb RunAs, exit

# === ONLY ELEVATED REACHES HERE ===

$transcriptPath = Join-Path $env:TEMP "WindowsSetup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $transcriptPath -IncludeInvocationHeader

try {
    Write-Host "Script Version: $ScriptVersion" -ForegroundColor DarkGray
    # full machine info banner here (Get-ComputerInfo / CIM for OS caption, Manufacturer, Model, ChassisTypes, PartOfDomain, etc.)
    # ...

    $machineType = Get-MachineType -AssumeDesktop:$AssumeDesktop -AssumeLaptop:$AssumeLaptop

    # Execute the 9 steps (each wrapped individually or the whole sequence in additional per-step try for isolation)
    # LocalAdmin (and any other password consumers) will have read $PasswordFile (if supplied) + cleaned the file; main finally guarantees remaining cleanup.
    # ...
} finally {
    # Guaranteed cleanup for any password material (even on exceptions/Ctrl-C)
    Remove-Variable -Name LocalAdminPassword, PasswordFile, plain, secure -Scope Script -Force -ErrorAction SilentlyContinue
    if ($PasswordFile -and (Test-Path $PasswordFile)) {
        Remove-Item -Path $PasswordFile -Force -ErrorAction SilentlyContinue
    }
    Stop-Transcript
    # Always emit the structured results table + write the persistent .txt report (header + facts + table + log paths + "ready for AD join")
    # Set exit code policy: $failed = $script:Results | Where Status -eq 'Failed'; if ($failed) { exit 1 } else { exit 0 }
}
```

- Update the Mermaid flowchart in the design to reflect: initial banner before the decision diamond; full "Start-Transcript + Print banner + machine info" only on the Yes/elevated branch; explicit finally around summary.
- Non-elevated path after the initial banner should print only the "Relaunching with administrative privileges..." message (no duplicate full machine info or early transcript attempt). Guard any transcript/report code behind `if (Test-Admin) { ... }` or place it exclusively after the `Request-Elevation` call. This must be resolved in the foundation PR.

**Password forwarding specifics** (addresses the key challenge):
- The parameter remains `[string]$LocalAdminPassword` (plain text) for simplicity of forwarding. **Known fragility**: Direct inclusion in `-ArgumentList` is sensitive to quotes, spaces, and special characters in the password. If the password contains `"`, the resulting command line will mis-parse on the elevated side.
- **Recommended robust forwarding (base64 encoding to avoid quoting issues)**:
  ```powershell
  if ($LocalAdminPassword) {
      $bytes = [System.Text.Encoding]::Unicode.GetBytes($LocalAdminPassword)
      $encoded = [Convert]::ToBase64String($bytes)
      $argList += '-LocalAdminPassword', $encoded   # note: still plaintext-encoded in argv; see Security
  }
  ```
  Then decode on receipt (in elevated context or inside the LocalAdmin step; also handle $PasswordFile):
  ```powershell
  $plain = $null
  if ($PasswordFile -and (Test-Path $PasswordFile)) {
      try {
          $content = Get-Content -Path $PasswordFile -Raw -ErrorAction Stop
          # support plain or base64 in the file
          try {
              $bytes = [Convert]::FromBase64String($content.Trim())
              $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
          } catch {
              $plain = $content.Trim()
          }
      } finally {
          Remove-Item -Path $PasswordFile -Force -ErrorAction SilentlyContinue
      }
  } elseif ($LocalAdminPassword) {
      try {
          $bytes = [Convert]::FromBase64String($LocalAdminPassword)
          $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
      } catch {
          # fallback for legacy direct-string callers or migration
          $plain = $LocalAdminPassword
      }
  }
  if ($plain) {
      $secure = ConvertTo-SecureString $plain -AsPlainText -Force
  } else {
      $secure = Read-Host -Prompt "Enter password for local Administrator account" -AsSecureString
  }
  ```
- The prompt always happens in the elevated context when no param is supplied. This is the recommended interactive path.
- Param (encoded or plain) is primarily useful for (a) already-elevated launches, (b) wrapper scripts, or (c) future unattended modes.
- **Strongly recommended for any param-based launch**: Use a minimal temp-file handoff (via `-PasswordFile`) instead of (or in addition to) the encoded value (see Security and Alternatives for sketch). The file path (not the secret) is passed on the command line. Always perform `Remove-Item` on the file + `Remove-Variable` (for both $LocalAdminPassword and any $plain/$secure) in a `finally` around the LocalAdmin logic and the overall elevated main try/finally. The authoritative main sketch and LocalAdmin step include the read + guaranteed cleanup.
- See Security section for full exposure analysis (transcript invocation header capture is unavoidable when using the param; treat such logs as secret-containing).

### Automatic Laptop vs. Desktop Detection

Implemented in `Get-MachineType` (called once after elevation). Prefers detection; switches are overrides for testing or when detection is ambiguous.

```powershell
function Get-MachineType {
    param([switch]$AssumeDesktop, [switch]$AssumeLaptop)

    if ($AssumeLaptop)  { return 'Laptop' }
    if ($AssumeDesktop) { return 'Desktop' }

    # Primary: Win32_SystemEnclosure ChassisTypes (most reliable per MS + community)
    try {
        $enclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
        $types = $enclosure.ChassisTypes
        # Common laptop/notebook values: 8=Portable, 9=Laptop, 10=Notebook, 11=Handheld, 12=Docking Station (sometimes), 14=Sub Notebook, 18=Laptop, 21=Portable, 30-32=Tablet variants
        $laptopTypes  = @(8,9,10,11,12,14,18,21,30,31,32)
        $desktopTypes = @(3,4,5,6,7,13,15,16,17,23,24,25)  # Desktop, Tower, MiniTower, etc.

        if ($types | Where-Object { $_ -in $laptopTypes })  { return 'Laptop' }
        if ($types | Where-Object { $_ -in $desktopTypes }) { return 'Desktop' }
    } catch { Write-Verbose "Chassis query failed: $_" }

    # Strong secondary: presence of battery (Win32_Battery)
    if (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue) {
        return 'Laptop'
    }

    # Tertiary: Win32_ComputerSystem.PCSystemType (1=Desktop, 2=Mobile)
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PCSystemType -eq 2) { return 'Laptop' }
        if ($cs.PCSystemType -eq 1) { return 'Desktop' }
    } catch {}

    # Fallback (rare): interactive
    Write-Warning "Could not reliably auto-detect form factor via WMI/CIM."
    do {
        $ans = Read-Host "Is this machine a (D)esktop or (L)aptop? [D/L]"
    } while ($ans -notin 'D','L','d','l')
    if ($ans -match '^[Ll]') { return 'Laptop' } else { return 'Desktop' }
}
```

This satisfies "no manual switches preferred" while retaining the existing param surface for overrides and diagnostics. Detection is performed only once.

### Step-by-Step Implementation Details (Concrete Techniques)

All steps live in the `#region Step Implementations` area. Each:
- Begins with `Write-Step`.
- Performs an idempotency / presence check where possible.
- Mutates only if needed.
- Calls `Add-Result` (or directly records) with clear `Details`.
- Ends with `Write-Success` or `Write-Skip`.

**1. UAC Never Notify**
- Key: `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`
- Values: `ConsentPromptBehaviorAdmin` (DWORD 0 = "Elevate without prompting"), `PromptOnSecureDesktop` (DWORD 0).
- Idempotency: Read both; if already 0/0, skip.
- Also consider `EnableLUA=1` (keep UAC "on" but at lowest level).
- Exact:
  ```powershell
  $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  $admin = (Get-ItemProperty -Path $key -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
  $secure = (Get-ItemProperty -Path $key -Name PromptOnSecureDesktop -ErrorAction SilentlyContinue).PromptOnSecureDesktop
  if ($admin -eq 0 -and $secure -eq 0) { Write-Skip ...; return }
  Set-ItemProperty -Path $key -Name ConsentPromptBehaviorAdmin -Value 0 -Type DWord
  Set-ItemProperty -Path $key -Name PromptOnSecureDesktop   -Value 0 -Type DWord
  ```

**2. Date & Time (automatic + location-based)**
- Time sync: `w32time` service → Automatic + Start; `Parameters\Type = 'NTP'`; `w32tm /config /update`; `w32tm /resync`.
- Time zone auto: 
  ```powershell
  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' -Name 'Start' -Value 3
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value' -Value 'Allow' -Force
  ```
- Idempotency: Service start type + a quick `w32tm /query /status` heuristic (or simply always apply; the settings are harmless to re-apply).

**3. Power Plan**
- Use built-in `powercfg /change` (simple, affects active scheme; sufficient for the stated requirements).
- Desktop:
  ```powershell
  powercfg /change monitor-timeout-ac 60
  powercfg /change standby-timeout-ac 0
  ```
- Laptop (AC = plugged; DC = battery):
  ```powershell
  powercfg /change monitor-timeout-dc 15
  powercfg /change standby-timeout-dc 20
  powercfg /change monitor-timeout-ac 15
  powercfg /change standby-timeout-ac 0
  ```
- Optionally also set hibernate-timeout-* = 0. No plan GUID switching needed unless future requirements demand "High Performance".
- Idempotency: Re-applying identical values is a no-op in effect; optionally query via `powercfg /query` and parse `GUID` subkeys for exact match (more complex, lower priority).

**4. Local Administrator Account**
- Use `Get-LocalUser`, `Enable-LocalUser`, `Set-LocalUser` (PowerShell 5.1+ LocalAccounts module; available on Win10/11 Pro).
- **Non-English Windows / localized built-in Administrator name**: The built-in Administrator account has a stable well-known SID (S-1-5-*-500). On non-English Windows the *name* is localized. For robustness:
  - Provide (or use) a small helper `Get-BuiltInAdministrator` that attempts SID-based resolution first:
    ```powershell
    function Get-BuiltInAdministrator {
        # Prefer SID (stable across localizations)
        $sid = (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE 'S-1-5-21-%-500'").SID
        if ($sid) { return Get-LocalUser -SID $sid -ErrorAction SilentlyContinue }
        # Fallback to English name (common on en-US and many enterprise images)
        return Get-LocalUser -Name 'Administrator' -ErrorAction SilentlyContinue
    }
    ```
  - Then `$admin = Get-BuiltInAdministrator` and use `.Name` for the Set/Enable calls (or pass the object where possible).
  - If the helper returns $null, treat as failure in the step (non-fatal overall; record Failed + guidance to manually enable the built-in admin by SID).
- The design targets the stable built-in admin account (SID-based preferred for v1 robustness). Non-English name localization is explicitly handled rather than left as a latent bug. Update non-goals and testing edges accordingly.
- **Idempotency guard (critical for zero-friction re-runs)**: Check state *before* any prompt or password handling using the SID-aware helper. Only prompt (or consume param/file) if the account is not already Enabled + PasswordNeverExpires. When a password source (`-LocalAdminPassword` or `-PasswordFile`) is explicitly supplied (wrappers, unattended), bypass the skip and force (re)set.
- Full recommended sketch (uses Get-BuiltInAdministrator for non-English robustness + SID where possible; complete password handling for $PasswordFile read+cleanup, base64 decode, or prompt; cleanup note for finally):
  ```powershell
  Write-Step "Configuring Local Administrator Account"
  $admin = Get-BuiltInAdministrator   # SID-preferring helper (see above); falls back to name
  if (-not $admin) {
      Add-Result 'LocalAdmin' 'Failed' 'Built-in Administrator account not found (even by SID)'
      Write-Warning "Could not locate built-in Administrator account by SID or name."
      return
  }
  # Use $plain (populated below from file/base64/prompt) for the skip condition
  $plain = $null
  if ($PasswordFile -and (Test-Path $PasswordFile)) {
      try {
          $content = Get-Content -Path $PasswordFile -Raw -ErrorAction Stop
          try {
              $bytes = [Convert]::FromBase64String($content.Trim())
              $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
          } catch { $plain = $content.Trim() }
      } finally {
          Remove-Item -Path $PasswordFile -Force -ErrorAction SilentlyContinue
      }
  } elseif ($LocalAdminPassword) {
      try {
          $bytes = [Convert]::FromBase64String($LocalAdminPassword)
          $plain = [System.Text.Encoding]::Unicode.GetString($bytes)
      } catch { $plain = $LocalAdminPassword }
  }
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
  if (-not $admin.Enabled) {
      Enable-LocalUser -SID $admin.SID   # or -Name $admin.Name ; SID preferred
  }
  Set-LocalUser -SID $admin.SID -Password $secure -PasswordNeverExpires $true
  # Note: caller of this function (or elevated main finally) must also do Remove-Variable for any $plain/$secure + any remaining $PasswordFile
  Add-Result 'LocalAdmin' 'Success' "Administrator account ($($admin.Name)) enabled + password set + never expires"
  Write-Success "Local Administrator configured"
  ```
- "Password never expires" + enable handled via the cmdlets above.
- Idempotency: Full skip (no prompt) when already Enabled + PasswordNeverExpires (unless a password source param/file forces a (re)set). Re-setting is safe when source supplied or state incomplete. The guard uses the helper and $plain (populated from file/base64/prompt). Cleanup of $PasswordFile (if used) + variables is required in the caller's finally (see main sketch and Security).

**5. Remote Desktop**
- Registry:
  ```powershell
  Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
  Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1  # NLA
  ```
- Firewall: `Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'`
- Service: `Set-Service TermService -StartupType Automatic; Start-Service TermService`
- Idempotency: Check `fDenyTSConnections -eq 0` first.

**6. Dell Optimizer Uninstall (Dell only)**
- Detection: `(Get-CimInstance Win32_ComputerSystem).Manufacturer -match 'Dell'`
- If not Dell → skip.
- If Dell:
  - Stop service(s): `Get-Service -Name '*DellOptimizer*' | Stop-Service -Force -ErrorAction SilentlyContinue`
  - Prefer `Get-Package -Name '*Dell*Optimizer*' | Uninstall-Package -Force` (where provider supports).
  - Fallback to registry scan (both 32/64-bit Uninstall keys) for `DisplayName -like '*Dell Optimizer*'`, extract `UninstallString`, run with `/silent`, `/remove`, or `/qn /norestart` (Dell docs mention `DellOptimizer.exe /remove`).
- Record "Uninstalled" or "Not present".
- Graceful on non-Dell or already-removed.
- **Known implementation risks / notes** (add during PR3): Some Dell Optimizer variants use different service names or MSI product codes; the registry scan + Get-Package should be resilient (try multiple DisplayName patterns such as "*Dell*Optimizer*", "*Optimizer Service*"). Service stop is often required to allow clean removal; include a short sleep or re-check if the uninstall string fails on first attempt. Non-fatal if removal partially succeeds.

**7. Non-English Office 365 Uninstall (preserve English)**
- This is the known tricky area (Click-to-Run / C2R, multiple "Microsoft 365 - xx-xx" entries, localization components).
- Primary approach (zero extra download): Registry enumeration of uninstall entries.
  ```powershell
  $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  $candidates = Get-ChildItem $keys -ErrorAction SilentlyContinue |
      Get-ItemProperty |
      Where-Object {
          $_.DisplayName -match 'Microsoft (365|Office|Office 16|M365)' -and
          $_.DisplayName -match ' - [a-z]{2}-[a-z]{2}' -and
          $_.DisplayName -notmatch '- ?en-us' -and
          $_.UninstallString
      }
  ```
- For each: parse/execute the `UninstallString` silently (`/qn /norestart` for MSI; append `/quiet` or equivalent for EXE-based). Stop any related services if present.
- Alternative (if reg method proves insufficient in testing): On-demand download of the Office Deployment Tool (small, official) + a generated `Config.xml` using `<Remove>` + `<Language ID="en-us"/>` only. The design prefers the reg method to avoid any download dependency beyond what `winget` already requires.
- "Equivalent to Get Help app flow": The reg scan + silent uninstall targets the same language-variant products the interactive flow removes.
- Record list of removed names (or "None detected").
- **Known implementation risks / notes** (add during PR3): Real C2R Office language components can appear under slightly different DisplayNames, as "Office 16 Click-to-Run Localization Component", or as provisioned packages/Appx. The scan should also consider `Get-AppxPackage *Office*` / language-related packages for completeness if testing on representative pre-stage images shows gaps. Stop related services (e.g. ClickToRun) before removal attempts where possible. Resolve or time-box the Open Question on falling back to ODT before or during the PR.

**8 & 9. Chrome + Adobe Acrobat Reader (winget)**
- Guard: `if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Add-Result 'Chrome' 'Failed' 'winget not found'; return }`
- Idempotency:
  ```powershell
  $listOut = & winget list --id Google.Chrome --accept-source-agreements 2>$null | Out-String
  if ($listOut -match 'Google\.Chrome') { Write-Skip "Chrome already present"; return }
  ```
- Install (non-interactive):
  ```powershell
  winget install --id Google.Chrome -e `
      --silent `
      --accept-package-agreements `
      --accept-source-agreements
  # Same for Adobe.Acrobat.Reader.64-bit (preferred over 32-bit on 64-bit Win11)
  ```
- Newer winget supports additional flags such as `--disable-interactivity` (use if available via version check).
- Source/package agreements are accepted explicitly on every run (handles first-run on a fresh image).
- Success detection via exit code + re-list or simple `Write-Success`.
- Fallback (rare): Direct HTTPS download of the Google/Adobe installer + `/silent` args (documented but secondary; `winget` is strongly preferred).
- **Known implementation risks / notes** (add during PR4): On ultra-fresh or certain enterprise images the winget source may not be fully initialized; perform a best-effort `winget source update --accept-source-agreements` inside the guard before the list/install (non-fatal if it fails). The --accept-* flags plus explicit source handling solve most first-run cases. Document any observed variance in package IDs or installer behavior during testing.

### Results Collection, Progress, and Final Report

- `$script:Results = [System.Collections.Generic.List[pscustomobject]]::new()`
- Helper:
  ```powershell
  function Add-Result {
      param([string]$Step, [ValidateSet('Success','Skipped','Failed','Warning')][string]$Status, [string]$Details)
      $script:Results.Add([pscustomobject]@{
          Step      = $Step
          Status    = $Status
          Details   = $Details
          Timestamp = Get-Date
      })
  }
  ```
- Called from every step function (and from catch blocks in main).
- Concrete post-steps summary + persistent report emission (drop-in pattern for PR1; must be inside the elevated `finally`):
  ```powershell
  # After steps (or in finally after Stop-Transcript)
  Write-Host "`n=================================" -ForegroundColor Magenta
  Write-Host "SETUP COMPLETE - SUMMARY REPORT" -ForegroundColor Green
  $script:Results | Format-Table -AutoSize -Wrap | Out-Host

  $reportPath = Join-Path $env:TEMP "WindowsSetupReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
  $reportContent = @"
Windows Pre-AD Workstation Setup Report
Version: $ScriptVersion
Timestamp: $(Get-Date -Format o)
Computer: $env:COMPUTERNAME
OS: $((Get-CimInstance Win32_OperatingSystem).Caption)
Manufacturer/Model: $((Get-CimInstance Win32_ComputerSystem).Manufacturer) / $((Get-CimInstance Win32_ComputerSystem).Model)
Form Factor (detected): $machineType
PartOfDomain: $((Get-CimInstance Win32_ComputerSystem).PartOfDomain)
Transcript: $transcriptPath

=== RESULTS ===
$($script:Results | Format-Table -AutoSize | Out-String)

Next step: Review above. Workstation is ready for Active Directory join (unless Failed entries above).
"@
  try {
      $reportContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force
  } catch {
      Write-Warning "Failed to write persistent report to $reportPath (disk full or permissions?). Summary was still shown on console."
  }
  Write-Host "Detailed log   : $transcriptPath"
  Write-Host "Report artifact: $reportPath"
  Write-Host "Review the summary above. The workstation is now ready for Active Directory join." -ForegroundColor Cyan

  # Exit code policy (always produce artifacts; non-zero only on failures)
  $failedCount = ($script:Results | Where-Object Status -eq 'Failed').Count
  if ($failedCount -gt 0) {
      Write-Warning "$failedCount step(s) failed. See report for details."
      exit 1
  } else {
      exit 0
  }
  ```
- The entire elevated work (banner through steps) must be wrapped so that Ctrl-C, exceptions in steps, or early termination still hit the `finally` for Stop-Transcript + report emission. See the authoritative main sketch in Invocation context handling.

### Logging Strategy
- `Start-Transcript -Path (Join-Path $env:TEMP "WindowsSetup_$(Get-Date -f yyyyMMdd_HHmmss).log") -IncludeInvocationHeader` *only after elevation succeeds* (see authoritative main sketch).
- All `Write-*` and host output captured.
- **Guaranteed cleanup**: Transcript + report emission must live inside a top-level `try { ... steps ... } finally { Stop-Transcript; emit table + write $reportPath }` (or equivalent structured handling). This ensures artifacts are produced even on exceptions, Ctrl-C, or partial runs. Disk-full / $env:TEMP unwritable is handled gracefully (warning + console summary still shown; do not let it abort the whole script before the report attempt).
- Persistent report (txt + optional csv) written to `$env:TEMP` (or configurable via param) for easy retrieval/hand-off. The concrete report content block (above) specifies the minimal required fields: version, timestamp, computer facts (OS, mfr/model, form factor, domain status), transcript path, full results table, and "ready for AD join" guidance. Report write failures are non-fatal but must be warned.

### Idempotency, Error Handling, and Resilience
- State checks before every mutating action (UAC, power, RD, admin flags, presence checks for uninstalls/installs).
- Every top-level step invocation in main is wrapped:
  ```powershell
  try {
      Set-UACNeverNotify
  } catch {
      Add-Result 'UAC' 'Failed' $_.Exception.Message
      Write-Warning "UAC step failed (continuing): $_"
  }
  ```
- `$ErrorActionPreference = 'Stop'` at script top for predictability inside functions; catches provide isolation.
- Uninstalls and installs that find "nothing to do" record `Skipped`.
- Winget / network-dependent steps can fail gracefully (report "winget install failed — manual install of Chrome/Reader may be required").

### Distribution Story (Zero Friction)
- **Primary**: `scripts/Setup-Windows.ps1`. Technician obtains via:
  - Internal file share (`\\it-tools\workstation-prep\Setup-Windows.ps1`).
  - USB drive (copy + launch).
  - One-time secure download.
- Recommended launch (handles elevation + policy):
  - Double-click a companion `Setup-Windows.cmd` (if provided):
    ```cmd
    @echo off
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Windows.ps1" %*
    ```
  - Or directly: `powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-Windows.ps1`
  - The script's self-elevation handles the admin requirement.
- **Companion .exe (desirable)**: On a build/admin workstation, use a tool such as PS2EXE (community project `MScholtes/PS2EXE` or equivalent):
  ```powershell
  Invoke-ps2exe -InputFile Setup-Windows.ps1 -OutputFile Setup-Windows.exe `
      -NoConsole -NoError -Title 'Windows Pre-AD Setup' -requireAdmin `
      -version '0.1.0'
  ```
  The resulting `.exe` is a single file, triggers UAC via embedded manifest, runs the embedded script logic, and requires no PowerShell execution policy concerns for the end user. Distribute the `.exe` the same way as the `.ps1`. Size is modest; it does not embed the entire .NET runtime in most configurations.
  **Testing requirement**: The built .exe *must* be validated for interactive `Read-Host -AsSecureString` password prompt behavior (console vs. windowed modes in PS2EXE have nuances) and for `-LocalAdminPassword` (base64 or `-PasswordFile`) forwarding/arg passing. Document any required PS2EXE switches (e.g. `-NoConsole` trade-offs) in the build notes/README. See also PR5 and Distribution notes.
- Versioning & updates: Increment `$ScriptVersion`; technicians re-obtain the latest artifact. No in-place updater in v1.
- Future: Could add a small `build.ps1` or GitHub Action that produces the `.exe` artifact on tag.

## Key Decisions

1. **Single `.ps1` is the mandatory primary artifact; `.exe` is a build-from-script companion only.**  
   Rationale: Satisfies "zero friction is mandatory" and "trivial to launch on a fresh Windows Pro machine" with zero pre-installs. A lone `.ps1` (or `.cmd` + `.ps1`) can be dropped anywhere and run with a one-liner or double-click. The `.exe` addresses teams that dislike PowerShell policy or want a "double-click only" experience, but is never the only delivery mechanism.

2. **Self-elevation with explicit parameter forwarding (including $LocalAdminPassword base64-encoded or $PasswordFile path for the temp-file handoff) + post-elevation prompt preference + Get-BuiltInAdministrator in LocalAdmin.**  
   Rationale: Meets the explicit requirement for automatic relaunch passing parameters (and the skeleton's existing surface). Interactive `Read-Host -AsSecureString` (post-elevation, guarded by full state check using the SID-aware helper) is the zero-friction default. Base64 for direct value (mitigates quoting); $PasswordFile (path only, secret in ACL'd temp file created by caller) is the recommended robust path for wrappers/unattended (keeps secret off argv and transcript header for the launching process). The full LocalAdmin sketch now wires Get-BuiltInAdministrator() into guard + set (using -SID), and complete if/else for $PasswordFile read+immediate delete + base64 decode + prompt, with cleanup in the elevated main finally + LocalAdmin. Risks (argv visibility for base64 path, transcript header for value-based launches, quoting) are called out; $PasswordFile path is the way to avoid them. "Remove-Item + Remove-Variable in finally" is now in the concrete sketches. Temp-file + helper were adopted in the synced code for v1 robustness on the exact pre-AD use case and non-English images. This satisfies "passing through parameters" while making the recommended secure path implementable. See LocalAdmin step, Request-Elevation, main sketch, Security. See also the idempotency guard for re-runnability.

3. **Multi-factor automatic laptop/desktop detection using `Win32_SystemEnclosure.ChassisTypes` (primary) + `Win32_Battery` + `Win32_ComputerSystem.PCSystemType`, with prompt fallback and `-Assume*` overrides.**  
   Rationale: Directly addresses "auto-detect ... no manual switches preferred". ChassisTypes is the most reliable documented method in the community and Microsoft guidance; battery presence and PCSystemType provide excellent corroboration. Prompt is a last-resort safety net that almost never triggers on real hardware.

4. **Use `winget` exclusively for Chrome and Acrobat Reader installs, with `--silent --accept-package-agreements --accept-source-agreements` (and `-e` exact ID).**  
   Rationale: Matches user's preference and works out-of-the-box on Windows 11 Pro. Handles updates, dependencies, and silent execution without custom downloaders or installers. Explicit agreement flags solve the "first-run" friction on fresh images.

5. **Registry enumeration + silent `msiexec`/uninstall-string execution for non-English Office removal (ODT as documented alternative only); similar registry + Get-Package + service-stop for Dell Optimizer.**  
   Rationale: Avoids mandatory extra downloads (preserves zero-friction and works offline for the Office/Dell parts). Registry scanning is the approach used successfully by many MSP/pre-stage scripts for C2R language packs. ODT provides a more "official" path if the simple method proves incomplete during implementation/testing.

6. **Structured `$script:Results` collection + `Start-Transcript` + final `Format-Table` + persistent report file.**  
   Rationale: Directly fulfills "clear progress, ... and produce a final confirmation/summary report". The combination gives both human-readable console output during the run and an auditable artifact for hand-off to the AD-joining team. Transcript captures everything for troubleshooting.

7. **Per-step `try/catch` isolation + state checks before mutation (idempotency where practical).**  
   Rationale: "Set it and forget it" requires that a single flaky step (e.g., transient winget hiccup, already-removed bloatware) does not leave the machine in a half-done state or force a full re-image. Re-runs become cheap and safe.

8. **Built-in facilities only (`CimInstance`/`Get-CimInstance`, `powercfg`, `Set-ItemProperty`, `Set-LocalUser`/`Enable-LocalUser`, `winget`, `Enable-NetFirewallRule`, etc.). No external modules or pre-reqs.**  
   Rationale: Constraint "Must work without requiring additional software pre-installation on the target machine beyond what ships with Windows."

## Alternatives Considered

- **GUI front-end (even a simple WinForms form for password + "Go")**: Rejected for v1. Introduces unnecessary complexity and potential friction (assembly loading, STA thread, visual styles). The existing `Write-Step` style + `Read-Host` for the one sensitive prompt is extremely low-friction and matches the "CLI with clear prompts" baseline in requirements/README.
- **Require the operator to always right-click → "Run as administrator"**: Rejected. Explicit user decision and requirements call for automatic self-elevation with param passthrough.
- **Primary reliance on Office Deployment Tool (ODT) + generated Config.xml for language removal**: Considered strongly (it is the "official" Microsoft-supported mechanism). Rejected as the *mandatory* path because it requires downloading an extra ~5-10 MB executable on every run (or pre-staging it) and maintaining version pins for the tool URL. Registry-based removal is lighter, faster, and sufficient for the stated goal of "uninstall all non-English language versions while preserving the English version."
- **Using only `Get-Package` / `Uninstall-Package` for everything (Dell + Office)**: Attractive but provider coverage is inconsistent across Win10/11 images and third-party installers. Design uses it as the preferred path with a robust registry fallback.
- **Embedding a full custom power plan (duplicate Balanced GUID and tweak sub-values via `/setacvalueindex`)**: Overkill. The simple `powercfg /change` commands exactly match the documented manual process requirements and are what technicians already use.
- **One-liner `irm https://... | iex` as the primary distribution story**: Rejected on security grounds (even with TLS). Design favors explicit copy + execute with `-File` (or the `.cmd` wrapper) from a trusted source.
- **Storing the local admin password in a temp file with tight ACLs for elevation hand-off**: Considered and now partially adopted as a documented low-complexity mitigation for the param-forwarding path (base64 + temp file with icacls/Set-Acl restricting to Administrators + current user, passed as `-PasswordFile`, read + deleted in finally). The interactive default + encoded value remains the v1 baseline for zero added friction in the common case. The temp-file variant is sketched in Security and Self-Elevation for implementers to use when wrappers or unattended param launches are common. This is a pragmatic hardening that does not change the primary interactive experience.

## Security

- **Elevation**: Uses the standard `Start-Process -Verb RunAs` pattern. No attempt to bypass UAC. The relaunched process is a full interactive admin PowerShell.
- **Local Administrator password**:
  - Never written to transcript in plain text when using `Read-Host -AsSecureString`.
  - When `-LocalAdminPassword` (or the base64-encoded form) is supplied on the command line:
    - The (encoded or plain) value **WILL** appear in the command line of the elevated `powershell.exe` process (visible via Task Manager, Process Explorer, `Get-CimInstance Win32_Process`, etc., for the lifetime of the process until variables are cleared).
    - Because `Start-Transcript -IncludeInvocationHeader` is used (required for full auditability), the **original command line containing the password will be written verbatim into the .log file** in `$env:TEMP` before any `Remove-Variable` can run.
  - Mitigations (interactive path is strongly preferred):
    - (a) Default to the post-elevation `Read-Host -AsSecureString` prompt (no param) for normal technician use.
    - (b) Use base64 encoding for the forwarded value (reduces but does not eliminate quoting/visibility risks).
    - (c) For any param-based or wrapper usage, use the temp-file handoff (now fully wired in the concrete sketches for PR1): before relaunch, `$tmp = New-TemporaryFile`; set ACLs via `icacls $tmp /grant "Administrators:F" /inheritance:r` (or `Set-Acl`); write the (plain or base64) value; pass `-PasswordFile $tmp` (the *path* only); in elevated code (LocalAdmin full sketch + main finally) read the content (plain or base64 support), convert, then guaranteed `Remove-Item -Force $tmp` + `Remove-Variable` (LocalAdminPassword/PasswordFile/plain/secure). See the synced Request-Elevation (forward path), LocalAdmin sketch (read+delete), and authoritative main try/finally (cleanup block). This keeps the secret off the argv (for the file case) and out of the transcript header for the launching process.
    - (d) Always use the provided `finally` blocks (main sketch + LocalAdmin) for Remove-Item + Remove-Variable. The sketches now implement the handoff end-to-end.
    - (e) The password is only the *initial* local admin credential on a pre-AD machine — it will typically be superseded or managed after domain join.
    - (f) Clear, prominent documentation in script header, README, and every log produced under param usage: "This transcript contains a secret (local admin password) because -LocalAdminPassword was supplied on launch. Treat the entire log file as sensitive."
  - For the built `.exe`, the same argv + transcript header exposure applies if the parameter path is used; interactive prompt inside the elevated context remains preferred. Test PS2EXE nuances for console/Read-Host and arg passing.
  - Treat any transcript or report generated from a `-LocalAdminPassword` launch as containing a secret.
- **Logging**: Transcript and report files are written to `$env:TEMP` (user-writable). No passwords or other secrets are intentionally included *in the interactive prompt path*. When the password param is used, the invocation header (and thus the transcript) will contain it; the design documents this explicitly and recommends the temp-file handoff + treating such logs as secret material. Technicians should treat all logs as containing configuration state and secrets when param forwarding was used.
- **Remote Desktop**: NLA is explicitly enabled (`UserAuthentication=1`) and only the standard "Remote Desktop" firewall group is enabled (no custom port or "allow any").
- **Network / winget**: Installs require outbound HTTPS to Microsoft package sources. On a completely air-gapped fresh image this step will fail gracefully (reported in summary); the rest of the configuration still completes.
- **Execution policy**: The launch guidance and self-elevation always include `-ExecutionPolicy Bypass`. This is required for zero-friction on fresh machines (default policy is often Restricted). The script itself does not change the machine's persistent execution policy.
- **Trust model**: The script must be obtained from a trusted internal source. No code-signing enforcement is built in (can be added later via Authenticode if required by policy).

## Observability

- **During run**: Cyan `==> Step` banners, Green `✓ success`, DarkGray `- skipped`, Yellow warnings. Sequential and easy to follow even if the technician walks away and returns.
- **Transcript**: Full capture (including invocation header with command line — note the password caveat) to a dated file in `%TEMP%`.
- **Structured summary**: Table at the end showing every step's final status + human-readable details. Easy to photograph or copy.
- **Persistent artifacts**: Timestamped `.txt` report (banner + machine facts + table + log paths) and optionally a `.csv` of the results list. Location printed clearly.
- **Machine context in every run**: Hostname, Manufacturer/Model, Chassis, OS version/caption, PartOfDomain status, current logged-on user, script version.
- **Future enhancements** (not v1): Write to Windows Event Log under a custom source, or emit a simple JSON summary for ingestion.

## Testing & Validation Strategy (for Implementation)

- **Primary**: Manual runs on clean Windows 11 Pro (and 10 Pro) Hyper-V / VMware VMs or physical test hardware.
  - Fresh OOBE / reset images.
  - Images with pre-installed Dell bloat.
  - Images with multi-language Office Click-to-Run preloads.
  - Both "laptop" (battery present) and "desktop" chassis.
  - Already-configured machines (verify skips).
- **Idempotency runs**: Execute twice in succession; second run should be almost entirely "Skipped" with no functional changes and no errors.
- **Error injection**: Remove `winget`, simulate missing Dell/Office packages, provide invalid password (should still succeed in setting a known one), run while on battery vs. AC for laptops.
- **Verification commands post-run** (documented in the script or a companion `Verify-Setup.ps1` stub):
  - `powercfg /query` (or the GUI) for timeouts.
  - `Get-LocalUser Administrator | fl Enabled,PasswordNeverExpires`.
  - Registry dumps for UAC, RDP, tzautoupdate.
  - `winget list` for the two apps.
  - `Get-ItemProperty ... \Policies\System` for UAC values.
  - Services and firewall state.
- **Edge**: Domain-joined machine (warn but proceed), non-English Windows UI (explicitly test the SID-based Get-BuiltInAdministrator helper + any localized strings), limited user rights before elevation, syntax/parse validation under stock PS 5.1.
- **No automated tests in v1**; a later PR can add Pester for the pure functions (`Test-Admin`, `Get-MachineType`, result helpers). Include a dedicated "PS 5.1 syntax validation + re-run idempotency on representative images" step in every relevant PR description.

## Implementation Notes / Evolution from Skeleton

- Keep the existing regions and helper style (`Write-Step` etc.).
- Expand the param block only if needed (add `-LogPath`, `-ReportPath`, `-Unattended` later).
- Move the machine-type detection and results collection into reusable helpers.
- Add a `finally` / `trap` or structured `try/finally` around the transcript and summary to guarantee cleanup.
- The 9 steps remain in the exact order listed in requirements.
- All TODOs in the skeleton will be replaced by the concrete logic above.
- A small amount of defensive code (e.g., `-ErrorAction SilentlyContinue` on CIM queries that may not exist on every SKU) is acceptable.
- Consider adding `Set-StrictMode -Version 3.0` (or Latest) after the param block for robustness.
- **Compatibility requirement (PS 5.1)**: *All* code examples, helpers, and committed script must be valid and parse/execute under the stock `powershell.exe` (Windows PowerShell 5.1) on Win10/11 Pro. No PS 7+ language features (ternary `?:`, `??`, `&&`/`||` pipeline chains in expressions, etc.). The Get-MachineType fallback was updated to classic if/else. Add explicit validation in the PR1 test plan: `powershell -NoProfile -Command { $null = [System.Management.Automation.Language.Parser]::ParseFile('Setup-Windows.ps1', [ref]$null, [ref]$null) }` (or run on a clean PS 5.1 VM/image). Document in Key Decisions / Implementation Notes: "All code must be valid and tested under Windows PowerShell 5.1 (powershell.exe) on Win10/11 Pro." Update testing strategy with a syntax/parse validation step.

## Open Questions

- Confirm full support matrix: Windows 10 Pro (specific builds?) in addition to Windows 11 Pro? Any minimum build number?
- Preferred persistent report location (e.g., always `%TEMP%`, or `C:\Windows\Temp\SetupReports`, or user's Desktop)? Should it be deleted after domain join or retained?
- Any appetite for a very small companion `Verify-Setup.ps1` (or function inside the main script) that a second technician can run to quickly re-validate the state before handing off?
- For the Office language removal: if the registry method leaves certain localization components or "Get Help" entries behind in real testing, is downloading the ODT (and pinning a recent version or using the latest known direct link) acceptable as a fallback, or must we stay strictly registry-only?
- Should the tool *warn and exit* (or require explicit `-Force`) if it detects the machine is already domain-joined (`PartOfDomain -eq $true`)?
- Future unattended / answer-file mode: preferred mechanism for supplying the password non-interactively (plain param file, DPAPI-protected file, environment variable, or something else)? Any compliance requirements around logging the fact that a password was set (without the value)?
- Any additional steps that have crept into the "standard" manual process since requirements were written (e.g., specific Windows Update settings, Defender exclusions, other pre-installed manufacturer apps, BitLocker prep, etc.)?
- Code-signing / execution policy stance in the target environment: will Authenticode signatures eventually be required, or is `-ExecutionPolicy Bypass` permanently acceptable for this pre-AD workflow?

---

## PR Plan

The following is a realistic, incremental, independently reviewable and mergeable PR strategy. Each PR delivers working, tested value and can be merged without blocking the others (later PRs simply fill in or polish). The skeleton is evolved in place.

1. **PR title**: `feat: foundation - robust self-elevation, logging, results collection, main flow skeleton, and basic always-present reporting`  
   **Files/components affected**: `scripts/Setup-Windows.ps1` (core changes + authoritative main try/finally + report emission block), `README.md` (minor launch examples update)  
   **Dependencies on other PRs**: None (base)  
   **Brief description**: Harden `Test-Admin`/`Request-Elevation` with full `-ExecutionPolicy Bypass`, support for both `-LocalAdminPassword` (base64) and `-PasswordFile` (temp-file path) forwarding (path-only for file case to keep secret off argv/header), quoting notes, and switch forwarding. Add guarded `Start-Transcript -IncludeInvocationHeader` + `Stop-Transcript` + report emission in `finally` (using the concrete example block, plus password var/file cleanup). Introduce `$script:Results` + `Add-Result`. Add minimal title banner (non-elev) + full machine-info banner (elev only), `$ScriptVersion`, and the machine-type stub + its call site in the elevated path. Refactor main per the authoritative sketch (initial banner, Request-Elevation that forwards file path or base64, then elevated try/finally with basic but *always-present* results table + minimal persistent .txt report containing header + facts + table + log paths + cleanup). Update script header with security/transcript-secret notes. The LocalAdmin placeholder will be updated in PR2 but the forwarding + cleanup + Get-BuiltInAdministrator wiring must be demonstrable in the foundation (via the provided sketches). Exit code policy implemented. Independently testable end-to-end: launch (with/without admin, using either pw mechanism), elevation, transcript + report artifact produced even on early exit, basic table visible, $PasswordFile cleaned. Demonstrate a re-run of the skeleton produces the report.

2. **PR title**: `feat: implement UAC, Date & Time, Power Plan, Local Administrator (with state guard), and Remote Desktop steps with full per-step idempotency`  
   **Files/components affected**: `scripts/Setup-Windows.ps1` (the five functions + helpers + main call sites + LocalAdmin guard + password decode logic)  
   **Dependencies on other PRs**: PR 1 (needs the foundation, results, elevation, report finally, and machine-type stub + call site)  
   **Brief description**: Replace the first five placeholders with full implementations using the exact registry keys, `powercfg /change`, `w32time` + `tzautoupdate` + location consent registry, `Get-BuiltInAdministrator` (SID helper) + `Get-LocalUser`/`Set-LocalUser`/`Enable-LocalUser` (plus the pre-prompt state guard for LocalAdmin using the helper and $plain from file/base64/param: skip entirely including prompt unless password source supplied), and Terminal Server + firewall + service commands. Add full per-step state checks + Write-Skip + Add-Result paths. Update `Get-MachineType` to the complete 5.1-compatible multi-factor CIM implementation. Ensure complete password handling ( $PasswordFile read+delete, base64 decode, or prompt) + SID-based Enable/Set + Remove-Variable/Remove-Item finally lives inside the LocalAdmin function (synced with elevation and main). *Demonstrate re-run of the machine after these steps produces Skipped for all five (including no password prompt on the LocalAdmin re-run, and correct behavior with -PasswordFile or base64).* Testable in isolation on a VM after PR 1.

3. **PR title**: `feat: implement Dell Optimizer and non-English Office uninstall steps with full per-step idempotency`  
   **Files/components affected**: `scripts/Setup-Windows.ps1` (the two uninstall functions + any shared uninstall helpers + known-risks notes)  
   **Dependencies on other PRs**: PR 1 (for flow/results + finally/report); PR 2 helpful but not strictly required  
   **Brief description**: Full Dell detection (`Win32_ComputerSystem.Manufacturer`), service stop, `Get-Package` + registry fallback + silent execution of uninstall strings (including `/remove` variants) + presence checks for skip. Office: registry scan across both Uninstall hives for language-tagged Microsoft 365/Office entries (exclude en-us), silent execution, collection of removed names + "known risks" implementation notes (C2R variations, possible Appx consideration). Both functions record detailed `Add-Result` + skip/success. Graceful skips on non-matches. *Demonstrate re-run produces Skipped for these steps.* Includes comments referencing the "Get Help" equivalence goal and why ODT is not the primary path. Add the 1-2 sentence known-risks notes from the design.

4. **PR title**: `feat: implement winget-based Chrome and Adobe Acrobat Reader installs with presence checks and idempotency`  
   **Files/components affected**: `scripts/Setup-Windows.ps1` (the two install functions + known-risks notes)  
   **Dependencies on other PRs**: PR 1 (flow + results + finally/report); benefits from PR 2/3  
   **Brief description**: Guard for `winget` availability (plus best-effort `winget source update`). Idempotency via `winget list --id ... --accept-source-agreements` parsing + skip. Exact `winget install --id ... -e --silent --accept-package-agreements --accept-source-agreements` for `Google.Chrome` and `Adobe.Acrobat.Reader.64-bit`. Clear success/failure recording. Notes on first-run agreement handling, 64-bit preference, and "known risks" (source state on ultra-fresh images). *Demonstrate re-run produces Skipped for the install steps.* Fallback messaging if winget missing. Add the 1-2 sentence known-risks notes from the design.

5. **PR title**: `chore: polish summary/reporting (excellent formatting + CSV), full end-to-end idempotency matrix, distribution artifacts (.cmd + .exe notes), and documentation`  
   **Files/components affected**: `scripts/Setup-Windows.ps1` (polish on report emission / table formatting / optional CSV / extra edge skips / variable cleanup in finally), `README.md` (full Getting Started + examples + .exe testing notes), `docs/requirements.md` (optional status update), new `scripts/Setup-Windows.cmd` (tiny launcher), .exe build notes / PS2EXE nuances comment  
   **Dependencies on other PRs**: PRs 1-4 (all step logic + per-step idempotency must exist)  
   **Brief description**: Polish (not introduce) the final table + persistent report (better formatting, optional CSV export, "excellent" presentation). Add the tiny `.cmd` wrapper. Update README with exact launch instructions (including param vs interactive + secret-log warnings), security notes, and how to build/test the `.exe` (explicitly call out testing interactive password prompt + forwarding behavior because of PS2EXE console/arg nuances). *Run and document a full end-to-end idempotency matrix* (fresh image + re-runs after each logical group, verifying Skipped where expected and no unnecessary prompts). Close any remaining TODOs and the "known risks" time-box items. This PR makes the tool "release ready" from UX, documentation, and verification perspectives. Focus is polish + verification; core functionality and per-step checks were delivered earlier.

6. **PR title (optional / follow-up)**: `docs: add .exe build script / CI note, explicit -PasswordFile handoff support, and optional unattended mode`  
   **Files/components affected**: New `build/Build-SetupExe.ps1` (or expanded comments + README), `README.md`, small param enhancement for `-PasswordFile` (the temp-file path) or future `-Unattended`.  
   **Dependencies on other PRs**: PR 5 (or parallel as mostly docs + thin wrapper)  
   **Brief description**: Provides a reusable build helper for the `.exe` artifact and documents PS2EXE testing requirements (including both password mechanisms and prompt behavior). Promotes the temp-file handoff (`-PasswordFile`) as the supported way to supply the credential non-interactively (consistent with the now-synced sketches in PR1/2). Adds a low-risk extension point for future answer-file style runs without changing the interactive zero-friction default. Can be deferred.

This plan yields 5 core PRs (1-5) that can be executed sequentially or with some parallelism (e.g., PR 3 and 4 after PR 1). Each delivers a shippable increment: after PR 1 a skeleton with working elevation/logging runs; after PR 2 the majority of configuration is automated; after PR 3+4 the full original manual process is covered; PR 5 makes it polished and documented.

---

*End of design document.*
