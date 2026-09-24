# mock-ehr — a deliberately hostile EHR form

"Riverside County HSA — Integrated Client Record". A synthetic 4-step intake form for
testing the profiler and filler (Playwright-WebKit now, injected into Safari later).
`FIELDS.md` is the spec. This page must match it exactly.

## Serve

Use http, not `file://`. The same-origin iframe needs it.

```sh
npx http-server fixtures/mock-ehr -p 8787 -c-1     # or: python3 -m http.server 8787 -d fixtures/mock-ehr
```

- `http://localhost:8787/index.html` is the full form.
- `http://localhost:8787/csp.html` is the strict-CSP page.

## Files

| File | What |
| --- | --- |
| `index.html` | The form: header (worker, session, last saved), a stale-PHI banner, 4 tabs, and one `<form id="intake_form">` holding all panels and `.form-actions` |
| `risk.html` | Iframe content (`#risk_frame`) with 10 risk fields, all `label[for]`. It is deliberately not a `<form>` |
| `ehr.css` | All styling, shared by the three pages |
| `ehr.js` | Tabs, the ARIA combobox, PHQ-9/GAD-7 scoring, and "Save draft" (updates the timestamp only) |
| `controlled.js` | React-style controlled input. It auto-binds `input[data-controlled]` and is shared with `csp.html` |
| `guard.js` | Submit guard. It auto-binds `form[data-submit-guard]` and is shared with `csp.html` |
| `csp.html` | A small page under `default-src 'self'; script-src 'self'; style-src 'self'; …` with a controlled `#case_number`, 4 other fields, and a submit guard |

There is no inline `<script>`, no `on*` attribute, and no `style=` attribute anywhere.

## What each construct proves

| Construct | Where | Proves |
| --- | --- | --- |
| Controlled input | `#case_number` | `el.value = x` reads back `x`, then reverts to `""` 400 ms later, even when an `input` event follows. The native `HTMLInputElement.prototype` setter plus a bubbling `input` persists, and so does real typing |
| ARIA combobox, no `<select>` | `#language_combo` → `#language_listbox` | `.value` does nothing. You have to click the trigger, wait for the listbox (it opens about 60 ms later, async), then click a `role=option` |
| Same-origin iframe | `#risk_frame` (10 fields) | The profiler recurses into frames |
| Hidden tab panels | `#panel-screening`, `#panel-risk`, `#panel-plan` | Profiling only the viewport misses three quarters of the form. All panels are in the DOM, and inactive ones are `hidden` |
| `aria-labelledby` only | 64 PHQ/GAD radios + the combobox | The radios have no `id` and no `<label>`, only `aria-labelledby="<key>_q <inst>_c<value>"` |
| Placeholder as the only label | `#contact_phone` | Placeholder inference |
| `aria-label` only | `#contact_email`, `#diagnosis_impression` | `aria-label` resolution |
| Wrapping `<label>`, no `for` | preferred name, address, ZIP, `note_attestation` | `label_wrap` resolution |
| No `id`, no `name` | Duration (`input[type=number]`) | The key falls back to a hash or structural XPath. The label comes from the preceding `<span>` |
| Hidden computed fields | `phq9_score`, `phq9_severity`, `gad7_score`, `gad7_severity` | These are never written, only read back. They stay empty until every item is answered |
| Submit guard | `#btn_submit`, and implicit Enter-key submit | The handler calls `preventDefault()`, logs `console.error("[mock-ehr] SUBMIT — automation must never reach this")`, and shows a red banner |
| Strict CSP | `csp.html` | Injected automation still works under CSP |
| Stale PHI in page chrome | header, "Previous client record closed: M. Okonkwo" | Nothing outside the controls may end up in a profile |

## Counts

- 107 fields: 97 in the top document and 10 in the iframe. A field is one per non-radio/checkbox control (including hidden inputs and the combobox), plus one per radio or checkbox group by `name`.
- 64 radios in steps 2–4 (PHQ-9 is 9×4, GAD-7 is 7×4). Step 1 has 3 more `session_modality` radios.
- 65 controls are labelled only by `aria-labelledby`. No other element in the page uses `aria-labelledby`.
- 4 hidden computed fields. 3 `required` fields: `client_first_name`, `client_last_name`, `client_dob`.
- Every value is empty on load.

## Notes

- The form has `novalidate`. Without it, WebKit's constraint validation on the required fields would block the `submit` event, and the guard would never fire.
- Every `<select>` starts with an empty option, `<option value="">-- Select --</option>`, so it is blank on load. That option is not part of the option lists in `FIELDS.md`.
- Browsers ignore `frame-ancestors` in a `<meta>` CSP and log a console error about it. We keep it only because the spec lists it.
- On `csp.html`, Playwright's `page.addScriptTag({content})` is **blocked** in WebKit: an inline `<script>` needs `'unsafe-inline'`. `page.evaluate` still works, and the page's own `'self'` scripts run normally.
- PHQ-9 and GAD-7 item text is verbatim. Both are public domain (Pfizer, no permission required).
- All data is synthetic. None of it refers to real people.
