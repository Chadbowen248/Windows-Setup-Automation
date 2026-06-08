# Windows-Setup-Automation

Automated, reproducible Windows machine setup and configuration for workstations **before Active Directory join**.

## Overview

This tool automates the common, tedious setup steps applied to all Windows Pro workstations. The user currently has these steps memorized and can perform them quickly, but they are repetitive and error-prone.

**Core principle**: Extremely low friction. Answer a few questions and the program handles the rest ("set it and forget it"). If the tool itself requires any meaningful setup or installation, it has already failed.

A CLI with clear prompts, progress, and a final confirmation is the baseline. A GUI is acceptable only if it introduces zero extra friction.

## Requirements

See the detailed, living requirements in [docs/requirements.md](docs/requirements.md).

### High-Level Goals
- Run the tool, answer a few questions, and walk away.
- Clear feedback during execution + a final summary of everything that was done.
- Must be trivial to launch on a fresh Windows Pro machine.

### Current Steps Being Automated (in typical order)
1. Set UAC to "Never notify"
2. Set Date & Time to automatic + location-based
3. Configure Power Plan (different for desktops vs laptops)
4. Set local administrator password + enable account + password never expires
5. Enable remote connections
6. Uninstall Dell Optimizer
7. Uninstall non-English Office 365 versions (keep English)
8. Install Chrome
9. Install Adobe Acrobat Reader

## Project Structure

```
Windows-Setup-Automation/
├── README.md
├── docs/
│   └── requirements.md
├── scripts/                    # PowerShell automation (primary)
│   ├── Setup-Windows.ps1
│   └── Setup-Windows.cmd       # Zero-friction launcher (double-click this)
├── configs/                    # (future) Winget manifests, etc.
└── tests/                      # Validation helpers (optional)
```

## Getting Started

**Recommended (zero-friction):**

Double-click `scripts\Setup-Windows.cmd` (it forces Bypass + NoProfile and passes through any args).

Or from an elevated or non-elevated prompt (it self-elevates):

```powershell
# From the folder containing the scripts\
.\scripts\Setup-Windows.cmd

# With password for wrappers / automation
.\scripts\Setup-Windows.cmd -LocalAdminPassword "YourP@ssw0rd"

# Even safer for wrappers (password never appears on argv or in transcript header)
.\scripts\Setup-Windows.cmd -PasswordFile C:\temp\pw.txt
```

The script will:
- Self-elevate if needed (with proper password forwarding).
- Ask for the local admin password only if not already supplied and the account isn't already in the desired state.
- Perform all steps with visible progress.
- Always produce a transcript + a timestamped report in %TEMP% with machine facts, results table, and next steps.

**ASCII-only source**: The entire script uses only plain ASCII. This avoids PowerShell 5.1 parser/encoding gotchas on Windows (non-ASCII characters like checkmarks have caused "phantom" string-terminator and brace errors in the past).

See `docs/design.md` for the full original PR plan, security notes (password handling, transcripts), and implementation details.

## Notes

- Pre-Active Directory workstation preparation.
- Requires administrative privileges for most steps (the script handles elevation).
- Some steps are Dell-specific; others are general.
- Technician ease-of-use is the #1 priority.

---

**Status**: Foundation (original PR1) + real step implementations (UAC, Date & Time, Power Plan, Local Admin with guard, Remote Desktop, Dell Optimizer, non-English Office, Chrome, Acrobat Reader) are complete and working. Simulation mode (`-Simulate`) is fully supported for safe testing on any machine. ASCII-only enforced.

The script has been verified to run correctly on Windows (no more parse errors). Use `-Simulate` here or on Windows for dry-runs.
