# P1.1 Safari transport spike — 2026-09-22

Safari 27.0 on macOS 27.0 (M1 Max). Mock EHR served by `page/scripts/serve.mjs` on :8787.
CLI: `.build/debug/scribeski`.

## Answers to the four spike questions

| # | Question | Answer |
| --- | --- | --- |
| 1 | Is `do JavaScript` synchronous only? | Yes: it returns the completion value. The job protocol (`start` → id, `poll`) round-trips; `ping` and the async combobox fill both work over it. |
| 2 | Escaping and size | ScriptingBridge (`doJavaScript:in:` via `perform`) and NSAppleScript both work. The full bundle (35 KB) and full-profile fill commands (~80 KB of JSON: the pretty-printed profile is 79 KB) cross the bridge without trouble. ScriptingBridge is the default: no AppleScript escaping. |
| 3 | CSP | **`do JavaScript` runs under a strict CSP** (`script-src 'self'`, no `unsafe-eval`/`unsafe-inline`): install, `ping`, `profile`, and `fill` all work on `csp.html`. **But the page's CSP still governs code inside the page**: `eval("1")` → "Refused to evaluate a string as JavaScript…", `new Function` → `EvalError`. The bundle's no-eval rule is required, not hygiene; the build enforces it. |
| 4 | Targeting | Front window's current tab. After a navigation the next command re-injects automatically (seen live: `index.html` → `csp.html`). A navigation *during* a job returns `navigated`; that path is coded but not yet exercised live. |

## Real-Safari results on the mock EHR

- `scribeski profile`: **107 fields, 0 unreachable**. Fingerprint identical to the Playwright-WebKit golden. No PHI (`K. Loo`, `2026-0917`, `REYES`, `AB-114322`, `Okonkwo`) in the profile.
- `scribeski fill` from the expected answers (47 results, identity check on `#record_banner`): **43 `ok`, 4 `computed_verified`, 0 other**. `case_number` survives the controlled-input revert; the combobox is clicked to ENGLISH; the page computes PHQ-9 18 / MODERATELY_SEVERE, matching ours. 0 page network requests (no autosave).
- A planted evidence quote was not present anywhere in the page or iframe DOM afterwards.
- `#submit_banner` still hidden after every fill: submit never fired.
- Identity mismatch (`AB-999999`) → `identity_mismatch`, nothing written.

## Findings that change other work

1. **Safari 27 reworded the disabled-toggle error**: "You must enable 'Allow JavaScript from
   Apple Events' in the Developer section of Safari Settings to use 'do JavaScript'."
   (Safari 26: "…option in Safari's Develop menu…"). Don't use Safari's text as onboarding
   copy; match the stable phrase (done in `TransportError.classify`).
2. **First use times out (-1712) while the Automation prompt is up.** Classified as
   `.timedOut` with "click Allow and try again". Onboarding (P4.3) should trigger the prompt
   deliberately with a harmless event (`get URL of current tab`) before anything else.
3. **The toggle can't be deep-linked.** Safari registers no URL scheme for its settings
   panes; opening them programmatically needs Accessibility (UI scripting), which is too
   broad a permission. Onboarding shows the two clicks and polls a harmless `do JavaScript`
   until it succeeds.
4. The TCC Automation grant attaches to the responsible app (here, the host terminal/app),
   not to the unsigned CLI. The signed app (P2.0) will get its own prompt.

## Not tested yet

- A real EHR (R7): cross-origin frames, session timeouts, logged-out detection.
- Multiple windows / a stored tab-URL match instead of the front tab.
