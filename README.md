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
├── scripts/           # PowerShell automation (primary)
├── configs/           # Winget manifests, config files, etc.
└── tests/             # Validation helpers (optional)
```

## Getting Started (Planned)

(Will be filled in once the initial script exists.)

Typical flow (target):
1. Technician obtains the script (shared location, USB, etc.).
2. Right-click → Run with PowerShell (or it self-elevates).
3. Answers a couple of prompts (e.g. desired local admin password).
4. Tool performs all steps with visible progress.
5. Final confirmation screen/report of what succeeded/failed/skipped.

## Notes

- This is pre-domain-join workstation preparation.
- Many steps require administrative privileges.
- Some steps are Dell-specific; others should be generally applicable.
- Ease of use for the technician is the #1 priority.

---

**Status**: PR 1 (foundation) implemented. The script now has robust self-elevation (with -PasswordFile and base64 support), results collection, guaranteed transcript + report emission, and machine-type detection. Individual step logic remains as placeholders (see PR Plan in docs/design.md).

## Getting Started (PR 1)

```powershell
# Basic zero-friction launch (self-elevates)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-Windows.ps1

# With password via param (for wrappers)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-Windows.ps1 -LocalAdminPassword "YourP@ssw0rd"

# Preferred for wrappers: pass path to a temp file containing the password (secret stays off argv/transcript header)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-Windows.ps1 -PasswordFile C:\temp\pw.txt
```

The script will always produce:
- A transcript in %TEMP%
- A structured console summary table
- A timestamped .txt report file in %TEMP% (machine facts + results + next steps)

See `docs/design.md` for the full PR 1 details, security notes, and the remaining PR plan.
