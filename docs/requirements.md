# Requirements — Windows-Setup-Automation

## Project Goal
Automate the common, tedious setup steps that are applied to **all Windows Pro workstations before they are joined to Active Directory**.

The experience must be extremely low-friction: answer a few questions and the tool handles the rest ("set it and forget it"). Any install or setup friction for the automation tool itself is unacceptable.

## Core Requirements

### Must Have
- Interactive experience with clear prompts, progress feedback, and confirmations.
- Final summary/report of everything that was changed / installed / uninstalled.
- All steps must be idempotent or safely re-runnable where possible.
- Must request elevation (admin rights) as needed.
- Support for user input where required (especially the local admin password).

### Current Manual Process (to be automated)
The following steps are performed in roughly this order today:

1. **UAC** — Set User Account Control to "Never notify".
2. **Date & Time** — Set to automatic + location-based.
3. **Power Plan**
   - **Desktops**
     - Turn off the display: 1 hour
     - Put the computer to sleep: Never
   - **Laptops**
     - On battery:
       - Turn off the display: 15 min
       - Put the computer to sleep: 20 min
     - Plugged in:
       - Turn off the display: 15 min
       - Put the computer to sleep: Never
4. **Local Administrator Account**
   - Prompt for (and set) the local administrator password.
   - Enable the local administrator account.
   - Set "Password never expires".
5. **Remote Desktop** — Enable remote connections.
6. **Dell Optimizer** — Uninstall (Dell machines only).
7. **Office 365** — Uninstall all non-English language versions while preserving the English version (equivalent to the "Get Help" app uninstall flow).
8. **Chrome** — Install (latest stable).
9. **Adobe Acrobat Reader** — Install (latest).

### Nice to Have
- A clean GUI (only if it does not introduce any installation or runtime friction).
- Ability to run in a more automated / answer-file style later.
- Logging to a file + on-screen summary.
- Detection of machine type (laptop vs desktop) to apply the correct power plan automatically.
- Skip or detect steps that are already in the desired state.

## Constraints
- **Zero friction for the operator**: The tool must be trivial to launch on a fresh or existing Windows Pro machine (ideally a single PowerShell script or one-liner).
- Target: Windows Pro workstations (10/11) prior to domain join.
- Must work without requiring additional software pre-installation on the target machine beyond what ships with Windows.
- Manufacturer-specific steps (currently Dell) should be handled gracefully (detect or prompt).

## Open Questions
- Exact target Windows versions (10 Pro, 11 Pro, specific builds)?
- Should the tool self-elevate, or must the user right-click → Run as administrator?
- Preferred delivery mechanism for zero friction (single `.ps1`, self-contained exe, etc.)?
- Any additional steps that should be added to the standard process?
- Logging / audit trail requirements (e.g. for compliance or hand-off to the AD-joining team)?

## Success Criteria
A technician can:
1. Copy/run the tool on a new workstation.
2. Answer a small number of prompts (local admin password + any machine-type questions).
3. Walk away.
4. Return to a clean, standardized machine ready for domain join, with a clear confirmation of what was performed.
