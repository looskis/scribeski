# Shipping Scribeski

What it takes to put a signed, notarized, auto-updating Scribeski on a social worker's Mac.
The code side is done and rehearsed (`scripts/release.sh --local`). The steps below need an
Apple Developer **Account Holder** or **Admin**, or decisions only the agency can make.

Team: `5CW397PZMC` · Bundle ID: `com.looski.scribeski` · Minimum macOS: 26.0 · Apple silicon only.

---

## 1. Certificates and the provisioning profile (Apple Developer, once)

1. **Register the App ID.** In Certificates, Identifiers & Profiles → Identifiers, add
   `com.looski.scribeski` as an explicit App ID. It needs no extra capabilities.
2. **Get a Developer ID Application certificate.** Only the Account Holder can create one.
   Create it in Certificates → +, choosing *Developer ID Application*. Download it and
   double-click to install it into the login keychain of the Mac that builds releases.
   - To check: `security find-identity -v -p codesigning` lists
     `Developer ID Application: … (5CW397PZMC)`.
3. **Create a Developer ID provisioning profile.** In Profiles → +, choose
   *Developer ID* → `com.looski.scribeski` → your Developer ID certificate. Name it
   `Scribeski Provisioning Profile` (the name the release script looks for), download it, and
   put it in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` (named by its UUID).
   - **Why it's needed:** session keys live in the *data-protection* keychain, which is
     "this device only" and never in backups, and that keychain needs a provisioned app.
     Release builds **refuse to start a session** without it (`SessionKeys.allowedBackends`)
     rather than quietly falling back to the login keychain.

## 2. Notarization credentials (once)

1. Create an app-specific password at <https://account.apple.com> → Sign-In and Security.
   An App Store Connect API key (`--key/--key-id/--issuer`) works too.
2. Store it in the keychain under the name the script expects:

   ```bash
   xcrun notarytool store-credentials scribeski-notary --apple-id YOU@EXAMPLE.COM --team-id 5CW397PZMC
   ```

## 3. Updates (Sparkle, once)

1. **Generate the EdDSA signing key.** After one release build, run Sparkle's
   `generate_keys`, found under `.build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
   - It stores the private key in your login keychain. **Back that key up.** Losing it means
     existing installs can't verify updates.
   - It prints the public key. It's already in the project as `SCRIBESKI_UPDATE_PUBLIC_KEY`
     (`A1e9c05SRr3g2SnCPiSVOMrmvtBqvVDBmBHeK+RbnWs=`, generated 2026-09-23). If you ever
     rotate the key, set the new public key there.
2. **Updates are hosted on the public repo's GitHub Releases.** Each release uploads the DMG
   and `appcast.xml`, and the app's feed is the stable
   `https://github.com/looskis/scribeski/releases/latest/download/appcast.xml`, set in the
   project as `SCRIBESKI_UPDATE_FEED` for Release builds; `UPDATE_FEED` overrides it. The
   repo must be public, because Sparkle downloads without logging in.
   - The feed itself is signed (`SURequireSignedFeed`), as well as each DMG. The first
     signing may ask for keychain access for `sign_update`: choose Always Allow.
3. What an update check sends: the app and OS version, to that host only. System profiling
   is off (`SUEnableSystemProfiling`). An agency can turn off automatic checks with a profile
   (`SUEnableAutomaticChecks` = false in the `com.looski.scribeski` domain).

## 4. Cutting a release

```bash
VERSION=0.1.0 BUILD=1 scripts/release.sh --publish
```

Without `--publish` it stops before uploading, so you can try the DMG first. `NOTES="…"`
sets the release notes.

The script:

1. rebuilds the page bundle;
2. builds `llama-server` from pinned source if it's missing;
3. runs every Swift test;
4. archives a Release build signed with Developer ID and hardened runtime, with the helper
   in `Contents/Helpers` and Sparkle's helpers re-signed;
5. checks for ad-hoc code, `get-task-allow`, and developer modes;
6. notarizes and staples the app, then builds, signs, notarizes and staples the DMG;
7. runs Gatekeeper's own assessment on both;
8. writes `appcast.xml` for this version, with the DMG's signature and the feed's own;
9. with `--publish`, creates the GitHub Release `vVERSION` with the DMG and the feed. The
   app's "latest" feed URL then points at it.

**Versioning.** `VERSION` is what people see. `BUILD` must go up with every release,
because Sparkle compares it.

## 5. Before the first pilot: check on a clean Mac

Use a Mac, or a fresh user account, that has never run Scribeski.

- [ ] Open the DMG, drag Scribeski to Applications, and launch it: no Gatekeeper warning.
- [ ] Onboarding opens. Grant Microphone and Call audio. The Safari check passes after you
      turn on "Allow JavaScript from Apple Events". The models download.
- [ ] Learn the pilot EHR's form (or import the agency's form pack).
- [ ] Run a role-played Zoom call with a colleague (both consenting). Stop, review, fill,
      then confirm.
- [ ] Unplug the headset mid-call: the transcript shows a short gap, and nothing crashes.
- [ ] Run a real 45-minute call on a 32 GB Mac: the transcript is ready seconds after
      Stop, and there's no backlog alarm.
- [ ] Settings → About → Check for Updates… finds nothing newer and shows no error.

## 6. Agency deployment (configuration profile)

Anything below can be locked with a configuration profile. Put it in the `com.looski.scribeski`
preferences domain as a managed preference. Locked settings show "Set by your agency".

| Key | Values | Default |
|---|---|---|
| `Retention` | `none` · `until_confirm` · `days:N` | `none` (zero recording) |
| `TranscriptDays` | 1–90: days a confirmed session's transcript and notes are kept. Unreviewed sessions go after the same number of days. | 30 |
| `UnconfirmedLimit` | 1–20: warn at N unreviewed sessions, refuse new ones at 2N | 3 |
| `TranscriptionEngine` | `parakeet` · `speechanalyzer` | `parakeet` |
| `Vocabulary` | array of strings (program names, medications) | none |
| `SUEnableAutomaticChecks` | bool | Sparkle asks on second launch |

A PPPC profile can pre-approve **Apple Events → Safari**
(`com.looski.scribeski`, signed by team `5CW397PZMC`). The microphone and call audio always
need the worker's own click; macOS doesn't allow pre-granting them.

## 7. Decisions only the agency can make

- **Retention:** which mode the agency allows, and who may change it. `none` is the only
  mode where the worker can truthfully say "this isn't being recorded".
- **Consent script:** what the worker says to the client at the start. The app asks the
  worker to confirm consent every session and records that in the audit log.
- **Privacy and security sign-off:** read SECURITY.md, and decide on its "Needs a decision"
  items.
- **Model licences:** Parakeet is CC BY 4.0 (credited in About). Gemma is under the Gemma
  Terms of Use. The Sortformer licence is noted as unconfirmed in the model catalog; counsel
  should confirm it before the second-voice flag ships to a customer.
