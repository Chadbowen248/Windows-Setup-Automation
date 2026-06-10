# Windows-Setup-Automation Status Note (as of last session)

## Current State
- Git commit: 15430d2 (HEAD) - "fix: robust external commands + truthful verification; Office non-English removal matches Get Help behavior (keep en-us)"
- Remote: git@github.com:Chadbowen248/Windows-Setup-Automation.git (pushed successfully)
- Script: scripts/Setup-Windows.ps1
- $ScriptVersion = '0.1.1', $ScriptCommit synced on every push.
- -Simulate fully supported and consistent across all steps (including LocalAdmin).
- Prints "Version: X Commit: Y Simulate: Z" banner.
- Has the new Invoke-Cmd helper + per-step try/catch isolation + truthful post-action verification (exit codes + re-queries) for Dell Optimizer, non-English Office, Chrome, and Adobe installs.
- Office step now targets the observable effect of "Get Help > Uninstall Office" for language bloat (QuietUninstallString preference, ClickToRun service stop, ec checks, re-scan + allEcsGood gate for Success) while absolutely preserving the en-us core.
- All original zero-friction / PS 5.1 / ASCII-only / Simulate guard / result reporting contracts preserved.
- See the "2026-06 real-hardware test findings + fixes" section below for motivation, Get Help/SaRA research, and what the next on-machine test should verify.

## The Ongoing Bug (User's Windows Side)
- Persistent ParserError on run (even after nuke/re-clone, git log showing correct commit d273b24, diagnostic showing array/reportLines version):
  - "The string is missing the terminator: "."
  - Points at Write-Warning "$failedCount step(s) failed. See report for details."
  - "Missing closing '}' in statement block or type definition."
  - Points at function Write-Success { ... }
  - FullyQualifiedErrorId : TerminatorExpectedAtEndOfString (or similar like AmpersandNotAllowed, MissingEndCurlyBrace in prior runs)
- This is **classic symptom of unclosed here-string** (`@" ... "@` with indented/non-column-0 closing line) earlier in the file. Parser gets "stuck in string mode", misparses all later code (strings, comments mentioning here-strings, functions, braces).
- User's diagnostics repeatedly show the *fixed* array version in their git clone.
- User insists: not running wrong/stale file, deleted everything, nuked repo + workspace, re-cloned fresh, still same error. "I swear it's the correct file".
- On this side (mac + pwsh): No such parse error on the current source. Simulation works for testing logic without Windows.

## What Was Tried/Fixed in Source
- Replaced old here-string report with $reportLines = @( ... ); $reportContent = $reportLines -join "`r`n" (avoids indentation/terminator gotcha entirely).
- Removed/cleaned explanatory here-string comments (to prevent them appearing in error messages).
- Added -Simulate param + guards (skip elevation, real file ops on PasswordFile, transcript, Out-File in sim; use mock data).
- Improved password source handling to be simulation-safe (no Test-Path/Remove-Item/Get-Content on null/empty).
- Added version/commit banner at top.
- Escaping for & in elevation args (Get-EscapedForArgument).
- Multiple force-checkouts, re-clones advised.
- Testing here with pwsh -File ... -Simulate to iterate without constant copy (user on Windows clone).

## Suspected Root Cause (Despite User's Re-Clones)
- User's local .ps1 on disk (the one being executed) still contains the old here-string report code, even if git log/diagnostic on the clone shows the array version.
- Possible: 
  - Running a different/stale .ps1 (e.g., old Desktop copy vs. the one inside git clone folder).
  - Local uncommitted edits or editor auto-saving the here-string back in.
  - Git checkout didn't overwrite (file locked, permissions, CRLF/LF issues on Windows affecting parser?).
  - Clone/pull not fully updating the working tree file (try `git checkout -- scripts/Setup-Windows.ps1` or delete file + checkout).
  - Running from wrong dir or PowerShell caching old parse.
  - (Less likely now) The GitHub commit tree the user cloned still had old code at time of clone (but log shows post-fix commit).
- Workspace source + pushes are clean/fixed. Parser here confirms no issue.

## Next Steps / Where We Left Off
- User going to bed. Wants note of status.
- On Windows: After any pull, ALWAYS `cd` into the git clone root, force `git checkout -- scripts/Setup-Windows.ps1` if needed, verify with `Select-String` for 'reportLines|reportContent|@\"' (should be array only, no active here-string), check banner shows correct commit, run from the scripts/ dir inside clone.
- To avoid copy fatigue: Do most iteration here with `pwsh -File scripts/Setup-Windows.ps1 -Simulate [params]`. Describe test case (e.g. "password with &, assume laptop, full report"), I run + paste output. Only pull to Windows for real (non-sim) test.
- If error persists after force checkout + fresh clone + run from clone: Paste full `Select-String` output for '@\"' + the exact run command + `git status`.
- Can further harden: Remove any remaining here-string risk (none in report now), make report in -Simulate fully static (no Get-CimInstance eval to avoid mac noise), add more self-diagnostics/version checks.
- Script is otherwise in good shape for PR1 foundation (elevation, results collection, placeholders for steps, simulation, escaping).

## How to Test Here (No Copy Needed)
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/Setup-Windows.ps1 -Simulate
# Add -AssumeLaptop etc. as needed. Output includes banner with commit + full simulated report.

Current source parses/runs clean here. The "phantom" errors only repro on files containing the old here-string.

## 2026-06 real-hardware test findings + fixes (Dell/Office/Installs)
User test on actual pre-AD Dell/Win11 Pro image:
- Dell Optimizer: NOT removed (script said success or skipped overall).
- Non-EN Office 365: NOT removed (multiple language variants from OEM preload remained).
- Chrome + Adobe Acrobat Reader: NOT installed.
- Script overall reported success (exit 0, green messages).

Root causes identified:
- Install-Chrome / Install-AdobeAcrobatReader did `winget ... | Out-Null` then unconditionally Add-Result 'Success'. No post-presence re-check, no $LASTEXITCODE inspection, no output capture. winget can fail (source not ready on fresh image, network, policy, ID variant) with no signal to the results table.
- Dell/Office had post-verification (good), but:
  - Dell discovery (exact InstallShield *DellOptimizer*.exe, Get-Package name patterns, reg -like '*Dell*Optimizer*') + service stop was not broad enough for the variant on that hardware.
  - Office regex was too strict (' - [a-z]{2}-[a-z]{2}' with spaces + specific product words). Real OEM entries use varying formats: " - fr-fr", "(fr-fr)", locale in parens, or appear as "Click-to-Run Localization Component" without the exact pattern. C2R ARP uninstall strings also need careful handling; raw append /quiet does not always equal the full scrub.
- "It said it was successful": overall report + lack of Failed on the install steps + possible Skipped on bloat (no matches) made it look clean. The per-step table would have shown the truth if more Faileds had been emitted.

Research on "Get Help feature in Windows and choose Uninstall Windows..." (user reference for Office):
- The relevant flow is Get Help app -> Office uninstall troubleshooter (or direct aka.ms/SaRA-officeUninstallFromPC). This launches the Microsoft Support and Recovery Assistant (SaRA) / command-line GetHelpCmd.exe -S OfficeScrubScenario -AcceptEula.
- It automates a comprehensive "remove any version of Office" (services, files, registry keys, Click-to-Run state, etc.). See Microsoft docs: "Office uninstall with the command line version of Get Help".
- It is a full scrub of the detected Office install(s). Not inherently "remove only non-en languages".
- To achieve the desired "that thorough clean but leave en-us": 
  - Use Office Deployment Tool (ODT) with a configuration.xml containing a targeted <Remove All="FALSE"><Product ID="O365ProPlusRetail"><Language ID="fr-fr" /><Language ID="es-es"/>...</Product></Remove>. This is the supported way to drop specific installed languages while preserving the base + en-us.
  - Or full scrub (Get Help / OffScrub) then reinstall English-only via company M365 / ODT add with only en-us.
- The script's in-box registry + UninstallString approach (chosen in original design to honor "built-in only, zero friction, no mandatory downloads") is a best-effort approximation that targets the per-language ARP entries common on Dell/OEM images. It will never be as thorough as the SaRA scrub for deeply embedded C2R state.

Actions taken (targeted hardening, no new full design cycle needed; this completes/polishes the area scoped in design.md PR3 "Dell + non-English Office" and PR4 "winget installs"):
- Added mandatory post-action verification + output/exit capture for both winget installs. Success only if the package ID is present in `winget list` afterward. Failures now emit Failed + tail of output + guidance.
- DellOptimizer: broader service/package/reg patterns (added *Optimizer*Service*), pre-discovery logging of exact candidates found, combined post-presence check (pkg OR reg OR exe still present), capture of command output tails in Details.
- NonEnglishOffice: significantly loosened locale detection (any xx-xx not containing en-us, plus explicit "Click-to-Run Localization Component" bloat), pre-removal logging of the exact DisplayNames being targeted (so next real test shows "Targeting: ..."), expanded comments with the Get Help research + why ODT is the "real" thorough path, kept the verification re-scan and Failed path.
- All changes stay ASCII-only. -Simulate still runs cleanly (early return in sim branches for those steps; real paths exercised on Windows).

Next real test at work should now:
- Show exactly what bloat candidates were discovered before any action.
- Truthfully report Failed (with details) for any install or removal that did not change the post-state.
- Give better clues in the report if C2R language entries need the Get Help full scrub or ODT instead.

If after next test the registry method is still insufficient for their specific preload images, we can add an optional thorough mode (download ODT to temp + generate remove-languages config for all but en-us) behind a switch, while keeping the current no-download path as default.

All original requirements + the "report truth, not fake success" goal are now better served.

