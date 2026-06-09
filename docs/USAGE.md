# Windows-Setup-Automation Usage Guide

This document provides detailed instructions and examples for using the `Setup-Windows.ps1` script to automate pre-Active Directory workstation setup on Windows Pro machines.

## Overview

The script performs a standard set of configuration steps that should be applied to every new or reset Windows Pro workstation **before** it is joined to Active Directory.

**Design goals**:
- Extremely low friction (answer a few questions → walk away)
- Clear progress feedback
- Always produces a transcript + structured report
- Safe to re-run (idempotent where possible)
- Works on a completely fresh machine with no extra software installed

The primary delivery mechanism is a single `.ps1` script + a tiny `.cmd` launcher.

## Prerequisites

- Windows 10 or 11 Pro (the script targets Pro editions)
- The script must be run on the target machine (it performs local configuration)
- Administrative privileges (the script self-elevates when needed)
- Internet access for winget-based installs (Chrome, Acrobat Reader)

No additional software is required on the target machine.

## Getting the Script

### Recommended: Clone from Git

```powershell
git clone https://github.com/Chadbowen248/Windows-Setup-Automation.git
cd Windows-Setup-Automation
```

### Alternative: Manual Copy

Copy the entire folder (or at minimum `scripts/Setup-Windows.ps1` + `scripts/Setup-Windows.cmd`) to the target machine via USB, network share, etc.

## Recommended Way to Run

### Zero-Friction (Recommended for Technicians)

Double-click `scripts\Setup-Windows.cmd`.

This launcher does the following:
- Forces `-NoProfile`
- Forces `-ExecutionPolicy Bypass` (required on fresh machines)
- Passes through any arguments you provide

### From PowerShell / Command Prompt

```powershell
# Basic run (self-elevates if needed)
.\scripts\Setup-Windows.cmd

# Or directly with PowerShell (also works)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Windows.ps1
```

## Command-Line Parameters

| Parameter              | Type     | Description                                                                 | Example |
|------------------------|----------|-----------------------------------------------------------------------------|---------|
| `-Simulate`            | Switch   | Dry-run mode. No system changes are made. Useful for testing and demos.    | `-Simulate` |
| `-LocalAdminPassword`  | String   | Provide the desired local Administrator password directly.                  | `-LocalAdminPassword "P@ssw0rd123"` |
| `-PasswordFile`        | String   | Path to a file containing the password (plain text or base64). Preferred for automation/wrappers. | `-PasswordFile C:\temp\adminpw.txt` |
| `-AssumeDesktop`       | Switch   | Force desktop power plan settings.                                          | `-AssumeDesktop` |
| `-AssumeLaptop`        | Switch   | Force laptop power plan settings.                                           | `-AssumeLaptop` |

### Password Handling (Important for Security)

**Best practice for interactive use**:
- Just run the script. It will prompt (after elevation) only if the local Administrator account is not already in the desired state.

**For wrappers / automation / scripting** (recommended):
```cmd
Setup-Windows.cmd -PasswordFile C:\temp\adminpw.txt
```

The `-PasswordFile` method is preferred because:
- The actual password never appears in the command line.
- It never appears in the transcript header on the launching process.

You can create the password file like this (on a secure machine):

```powershell
# Create a temp file with tight ACLs
$tmp = New-TemporaryFile
"SuperSecretP@ssw0rd123" | Out-File -FilePath $tmp.FullName -Encoding UTF8
# Restrict permissions (example)
icacls $tmp.FullName /inheritance:r /grant:r "Administrators:F" "YourUser:F"
```

## Common Usage Examples

### 1. Technician on a brand new machine (most common)

```cmd
cd C:\Setup
Setup-Windows.cmd
```

- Double-click the `.cmd` or run the command above.
- The script self-elevates.
- It will ask for the local Administrator password (only once, unless already configured).
- Walk away. Come back to a clean report.

### 2. Dry-run / testing (on any machine, including this one)

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Windows.ps1 -Simulate
```

Or on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Windows.ps1 -Simulate
```

This is extremely useful for:
- Verifying the script works after changes
- Demonstrating what will happen
- Testing on non-Windows machines (macOS + PowerShell 7 works great)

### 3. Supply password for automation / imaging

```powershell
# Using a password file (recommended)
.\scripts\Setup-Windows.cmd -PasswordFile \\server\share\adminpw.txt

# Or directly (less secure - appears in process list)
.\scripts\Setup-Windows.cmd -LocalAdminPassword "P@ssw0rd123"
```

### 4. Force laptop or desktop power settings

```powershell
.\scripts\Setup-Windows.cmd -AssumeLaptop
.\scripts\Setup-Windows.cmd -AssumeDesktop
```

### 5. Full command line example with multiple options

```powershell
.\scripts\Setup-Windows.cmd -PasswordFile C:\temp\pw.txt -AssumeLaptop -Simulate
```

## What the Script Does (Step by Step)

The script executes the following steps in order (with progress output):

1. **UAC** — Sets "Never notify" (lowest level).
2. **Date & Time** — Enables automatic time + location-based time zone.
3. **Power Plan** — Applies appropriate timeouts (desktops vs laptops, AC vs battery).
4. **Local Administrator** — Enables the built-in account, sets the password, and sets "Password never expires". Skips the prompt on re-runs if already correct.
5. **Remote Desktop** — Enables RDP with Network Level Authentication.
6. **Dell Optimizer** — Uninstalls if present on Dell hardware.
7. **Non-English Office** — Removes language packs for Office 365 while preserving English.
8. **Google Chrome** — Installs via winget (with presence check).
9. **Adobe Acrobat Reader** — Installs via winget (with presence check).

Each step reports `Success`, `Skipped`, or `Failed` and records the result.

## Output & Reporting

The script always produces:

- A full transcript in `%TEMP%` (e.g. `WindowsSetup_20260608_143022.log`)
- A structured text report (e.g. `WindowsSetupReport_20260608_143022.txt`)

The report contains:
- Version and commit hash
- Machine information (name, OS, manufacturer, form factor, domain status)
- Timestamped results table for every step
- "Next steps" guidance

Example (simulated) report header:

```
Windows Pre-AD Workstation Setup Report
Version: 0.1.0
Commit: d273b24
...
```

## Verifying the Version You're Running

Every run prints this at the very top:

```
Version: 0.1.0  Commit: d273b24  Simulate: True
```

Compare the commit hash against your git log to confirm you're running the expected version.

## Idempotency & Re-running

The script is designed to be safe to run multiple times:

- Most steps detect current state and skip with a clear message.
- The local Administrator step will **not** re-prompt for a password if the account is already enabled with "Password never expires".
- Re-running on an already-configured machine should result in mostly "Skipped" results.

## ASCII-Only Source

The entire script (including all strings and comments) uses only plain ASCII characters. 

This rule was added after discovering that Unicode characters (such as checkmarks) in the source could cause confusing "string missing the terminator" and brace-matching parse errors on Windows PowerShell 5.1 when the file was not saved with the correct encoding.

## Simulation Mode (`-Simulate`)

Extremely useful for:

- Testing after changes (run on macOS, Linux, or any Windows box)
- Training / demos
- Verifying logic without side effects

In simulation mode:
- No elevation is performed
- No registry, services, or software changes are made
- A simulated report is still produced

Example (run from anywhere):

```powershell
pwsh -File /path/to/scripts/Setup-Windows.ps1 -Simulate -AssumeLaptop
```

## Troubleshooting

**"The string is missing the terminator" or similar parse errors**

- Make sure you are running the version from the git repository (check the commit in the banner).
- Force-restore the script file: `git checkout -- scripts/Setup-Windows.ps1`
- Avoid editing the `.ps1` in basic Notepad (use VS Code, Notepad++, etc. saved as UTF-8).

**Script doesn't self-elevate**

- Run from an account that has local admin rights.
- The script attempts to relaunch itself with `Start-Process -Verb RunAs`.

**Winget not found**

- On very fresh Windows 11 images, winget may need a source update. The script attempts this automatically. If it still fails, the installs will be reported as failed (you can install manually afterward).

**Dell Optimizer or Office steps do nothing**

- These steps are intentionally skipped on non-Dell machines or when no non-English Office language packs are detected.

## Advanced / Automation Usage

```powershell
# Fully unattended example (using a password file created with proper ACLs)
$pwFile = "\\secure-share\admin-pw.txt"
.\scripts\Setup-Windows.cmd -PasswordFile $pwFile

# Combine with other automation
.\scripts\Setup-Windows.cmd -PasswordFile $pwFile -AssumeDesktop
```

See `docs/design.md` for deeper security notes around password handling and transcripts.

## Verification After Run

After the script completes:

1. Review the report file in `%TEMP%` (newest `WindowsSetupReport_*.txt`).
2. Optionally run a quick manual verification:
   - Check UAC settings
   - Verify local Administrator is enabled with "Password never expires"
   - Confirm Chrome and Acrobat Reader are installed
   - Test RDP connectivity (if applicable)

## Next Steps After This Script

This script prepares the machine for domain join. Typical follow-up steps (outside the scope of this tool):

- Join the machine to Active Directory
- Apply Group Policy
- Install additional line-of-business software
- Run any post-join configuration scripts

## Getting Help / Reporting Issues

- Check the transcript in `%TEMP%` first (contains the full execution log).
- The report file contains a machine-readable summary of every step.
- For development or simulation testing, use `-Simulate` liberally.

---

**ASCII-only rule**: This entire project (source, strings, comments, docs) uses only plain ASCII to avoid PowerShell 5.1 encoding/parser issues on Windows.
