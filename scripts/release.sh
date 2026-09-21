#!/bin/sh
# Builds a shippable Scribeski (BUILD_PLAN P4.1): Release archive signed with Developer ID and
# hardened runtime, the llama-server helper inside, notarized and stapled, in a signed,
# notarized, stapled DMG. Then checks it the way Gatekeeper will.
#
#   VERSION=0.1.0 BUILD=1 scripts/release.sh           full release
#     (PROVISIONING_PROFILE defaults to "Scribeski Provisioning Profile"; UPDATE_FEED to the
#     project's feed)
#   … scripts/release.sh --publish                     and upload the DMG + appcast.xml as a
#                                                       GitHub Release (the feed's repo, public)
#   scripts/release.sh --local                          no notarization, Apple Development
#                                                       signing: rehearses every other step
#
# Admin prerequisites (see SHIPPING.md): a "Developer ID Application" certificate for team
# 5CW397PZMC in the login keychain, and notarytool credentials stored once with
#   xcrun notarytool store-credentials scribeski-notary --apple-id … --team-id 5CW397PZMC
# For updates, Sparkle's EdDSA private key in the keychain (generate_keys) — see SHIPPING.md.
# Its public key is in the project (SCRIBESKI_UPDATE_PUBLIC_KEY); UPDATE_PUBLIC_KEY overrides it.
set -eu
cd "$(dirname "$0")/.."

LOCAL=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --publish) PUBLISH=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done
[ $LOCAL = 1 ] && [ $PUBLISH = 1 ] && { echo "--publish needs a notarized build: drop --local" >&2; exit 2; }
TEAM=5CW397PZMC
VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' App/Scribeski.xcodeproj/project.pbxproj | head -1)}"
BUILD="${BUILD:-$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' App/Scribeski.xcodeproj/project.pbxproj | head -1)}"
PROFILE="${NOTARY_PROFILE:-scribeski-notary}"
# The update feed baked into Release builds (project setting SCRIBESKI_UPDATE_FEED); UPDATE_FEED overrides.
FEED="${UPDATE_FEED:-$(sed -n 's/.*SCRIBESKI_UPDATE_FEED = "\(https:[^"]*\)";/\1/p' App/Scribeski.xcodeproj/project.pbxproj | head -1)}"
OUT=".build/release/$VERSION"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

if [ $LOCAL = 1 ]; then
  IDENTITY="Apple Development"
  SIGN_ID=$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')
  SIGNING="SCRIBESKI_ENTITLEMENTS=Scribeski.entitlements"
else
  IDENTITY="Developer ID Application"
  security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM)" \
    || fail "no Developer ID Application certificate for team $TEAM in the keychain (admin: SHIPPING.md §1)"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool credentials named $PROFILE (admin: SHIPPING.md §2)"
  # Session keys need the data-protection keychain: a provisioned build (SHIPPING.md §1).
  PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-Scribeski Provisioning Profile}"
  FOUND=""
  for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile; do
    [ -f "$f" ] || continue
    name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)
    [ "$name" = "$PROVISIONING_PROFILE" ] && FOUND="$f"
  done
  [ -n "$FOUND" ] || fail "the provisioning profile \"$PROVISIONING_PROFILE\" isn't installed (admin: SHIPPING.md §1)"
  # Sign with exactly the certificate the profile names: an account can have several
  # Developer ID certificates, and a name alone is ambiguous to codesign.
  SIGN_ID=$(security cms -D -i "$FOUND" | python3 -c '
import hashlib, plistlib, subprocess, sys
certs = [hashlib.sha1(c).hexdigest().upper() for c in plistlib.loads(sys.stdin.buffer.read())["DeveloperCertificates"]]
have = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
print(next((c for c in certs if c in have), ""))')
  [ -n "$SIGN_ID" ] || fail "none of the profile's certificates has its private key in this keychain (SHIPPING.md §1)"
  SIGNING="SCRIBESKI_ENTITLEMENTS=Scribeski-Release.entitlements"
  [ -n "$FEED" ] || echo "warning: no update feed set: this build won't check for updates (SHIPPING.md §3)"
fi

step "Scribeski $VERSION ($BUILD), signing: $IDENTITY ($SIGN_ID)"
rm -rf "$OUT"
mkdir -p "$OUT"

step "Page bundle is current"
if command -v npm >/dev/null; then
  (cd page && npm run -s build >/dev/null)
  git diff --quiet -- Sources/FormDriver/Resources/scribeski-page.js 2>/dev/null \
    || echo "note: page bundle rebuilt and differs from the index; commit it with this release"
fi

step "llama-server helper (pinned source)"
[ -x App/Helpers/llama-server ] || scripts/build-llama-server.sh
cat App/Helpers/llama-server.version

step "Tests"
scripts/swift-test.sh >"$OUT/tests.log" 2>&1 || { tail -30 "$OUT/tests.log"; fail "tests failed ($OUT/tests.log)"; }
grep -E "Test run with" "$OUT/tests.log" | sed 's/^/  /'

step "Archive"
xcodebuild -project App/Scribeski.xcodeproj -scheme Scribeski -configuration Release \
  -archivePath "$OUT/Scribeski.xcarchive" -derivedDataPath .build/xcode-release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM=$TEAM "$SIGNING" \
  SCRIBESKI_PROFILE="${PROVISIONING_PROFILE:-}" \
  OTHER_CODE_SIGN_FLAGS=--timestamp MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ${UPDATE_FEED:+SCRIBESKI_UPDATE_FEED="$UPDATE_FEED"} ${UPDATE_PUBLIC_KEY:+SCRIBESKI_UPDATE_PUBLIC_KEY="$UPDATE_PUBLIC_KEY"} \
  archive >"$OUT/archive.log" 2>&1 || { grep -E "error:" "$OUT/archive.log" | head; fail "archive failed ($OUT/archive.log)"; }
APP="$OUT/Scribeski.app"
ditto "$OUT/Scribeski.xcarchive/Products/Applications/Scribeski.app" "$APP"

step "Sign Sparkle's helpers (inside out), then the app"
# Sparkle ships its helpers ad-hoc signed; notarization needs them under our identity with
# hardened runtime and a timestamp. Its XPC services are only for sandboxed apps: removed.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ENT="$OUT/entitlements.plist"
codesign -d --entitlements - --xml "$APP" >"$ENT" 2>/dev/null
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
for x in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$x"
done
codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$ENT" "$APP"

step "Checks on the built app"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1
HELPER="$APP/Contents/Helpers/llama-server"
[ -x "$HELPER" ] || fail "llama-server isn't in Contents/Helpers"
codesign -dv "$HELPER" 2>&1 | grep -q "flags=.*runtime" || fail "llama-server isn't signed with hardened runtime"
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || fail "the app isn't signed with hardened runtime"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  fail "the app has get-task-allow (a debug entitlement)"
fi
# Developer modes are compiled out of Release (#if DEBUG): no trace of them in the binary.
# (Checks the type name and long literals: optimized Swift keeps short strings inline.)
if strings "$APP/Contents/MacOS/Scribeski" | grep -E "DevModes|--transcribe-probe|--auto-session|devSilenceSource|--sidecar-check"; then
  fail "the Release binary contains developer modes (above)"
fi
ADHOC=$(find "$APP" \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" -o -perm -111 -type f \) | while read -r code; do
  if codesign -dv "$code" 2>&1 | grep -q "flags=.*adhoc"; then echo "$code"; fi
done)
[ -z "$ADHOC" ] || fail "ad-hoc signed code inside the app: $ADHOC"
echo "  signatures, hardened runtime, entitlements, no developer modes: ok"

if [ $LOCAL = 0 ]; then
  step "Notarize the app"
  ditto -c -k --keepParent "$APP" "$OUT/Scribeski.zip"
  xcrun notarytool submit "$OUT/Scribeski.zip" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-app.log"
  grep -q "status: Accepted" "$OUT/notary-app.log" || fail "notarization rejected: xcrun notarytool log <id> --keychain-profile $PROFILE"
  xcrun stapler staple "$APP"
  rm "$OUT/Scribeski.zip"
fi

step "DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Scribeski.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Scribeski-$VERSION.dmg"
hdiutil create -quiet -volname "Scribeski $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [ $LOCAL = 0 ]; then
  codesign --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-dmg.log"
  grep -q "status: Accepted" "$OUT/notary-dmg.log" || fail "DMG notarization rejected"
  xcrun stapler staple "$DMG"

  step "Gatekeeper"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  xcrun stapler validate "$DMG"
fi

step "Update feed"
SIZE=$(stat -f %z "$DMG")
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
# GitHub Releases: the feed is …/releases/latest/download/appcast.xml, each DMG under its tag.
REPO=$(printf '%s' "$FEED" | sed -n 's|^https://github.com/\([^/]*/[^/]*\)/releases/.*|\1|p')
if [ -n "$REPO" ]; then
  DMG_URL="https://github.com/$REPO/releases/download/v$VERSION/Scribeski-$VERSION.dmg"
else
  DMG_URL="${FEED:-https://UPDATE-HOST/appcast.xml}"
  DMG_URL="${DMG_URL%/*}/Scribeski-$VERSION.dmg"
fi
SIGN_UPDATE=$(find .build/xcode-release -path '*Sparkle*/bin/sign_update' -type f 2>/dev/null | head -1)
ENCLOSURE="length=\"$SIZE\""
if [ $LOCAL = 0 ]; then
  [ -n "$SIGN_UPDATE" ] || fail "Sparkle's sign_update wasn't found in the build"
  ENCLOSURE=$("$SIGN_UPDATE" "$DMG") \
    || fail "couldn't sign the DMG for updates: is the Sparkle private key in this Mac's keychain? (SHIPPING.md §3)"
fi
cat >"$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Scribeski</title>
    <item>
      <title>Scribeski $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <enclosure url="$DMG_URL" type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
XML
# The app requires a signed feed (SURequireSignedFeed): the signature is embedded in the XML.
[ $LOCAL = 0 ] && "$SIGN_UPDATE" "$OUT/appcast.xml"
echo "  $DMG"
echo "  sha256 $SHA"
echo "  feed: $OUT/appcast.xml (DMG at $DMG_URL)"

if [ $PUBLISH = 1 ]; then
  step "Publish"
  [ -n "$REPO" ] || fail "--publish uploads to GitHub Releases: UPDATE_FEED must be https://github.com/OWNER/REPO/releases/latest/download/appcast.xml"
  [ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = "PUBLIC" ] \
    || fail "$REPO must be public: Sparkle downloads updates without logging in"
  gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --latest \
    --title "Scribeski $VERSION" --notes "${NOTES:-Scribeski $VERSION ($BUILD).}"
  echo "  published: https://github.com/$REPO/releases/tag/v$VERSION"
fi
[ $LOCAL = 1 ] && echo "  (--local: not notarized; Gatekeeper will refuse it on another Mac)"
exit 0
