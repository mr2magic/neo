#!/bin/bash
# Build NEO Pocket and put it on a plugged-in iPad or iPhone, signed with your
# own Apple developer team. Run it from Terminal (not an editor's or an
# agent's shell): signing needs the login keychain, and unlocking it asks for
# your Mac password.
#
#   pocket/scripts/build-ios.sh              iCloud library (iCloud Drive → NEO Pocket)
#   pocket/scripts/build-ios.sh --no-icloud  on-device library (On My iPad → NEO Pocket)
#
# Your IDs live in pocket/scripts/local.env (not in git); copy
# local.env.example to start one. The Xcode project itself is left alone.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pocket="$(dirname "$here")"
root="$(dirname "$pocket")"

[ -f "$here/local.env" ] || { echo "No $here/local.env — copy local.env.example and fill it in."; exit 1; }
# shellcheck source=/dev/null
source "$here/local.env"
: "${TEAM:?TEAM missing from local.env}" "${BUNDLE_ID:?BUNDLE_ID missing from local.env}" "${DEVICE:?DEVICE missing from local.env}"
ICLOUD_CONTAINER="${ICLOUD_CONTAINER:-iCloud.$BUNDLE_ID}"

icloud=1
[ "${1:-}" = "--no-icloud" ] && icloud=0

# the desktop's editor, copied in (pocket/README.md, "Building for iOS")
echo "Copying the editor…"
cd "$pocket"
[ -d node_modules ] || npm install
cp "$root/app.js" "$root/covers.js" "$root/styles.css" "$root/i18n.js" www/
cp "$root/node_modules/jszip/dist/jszip.min.js" www/
cp -R "$root/fonts" "$root/locales" www/
npx cap sync ios >/dev/null

# entitlements for your team, outside the project
build="$pocket/ios/build"
mkdir -p "$build"
ent="$build/Pocket.entitlements"
if [ $icloud = 1 ]; then
  cat > "$ent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array><string>$ICLOUD_CONTAINER</string></array>
	<key>com.apple.developer.icloud-services</key>
	<array><string>CloudDocuments</string></array>
	<key>com.apple.developer.ubiquity-container-identifiers</key>
	<array><string>$ICLOUD_CONTAINER</string></array>
</dict>
</plist>
EOF
else
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict/>\n</plist>\n' > "$ent"
fi

security unlock-keychain ~/Library/Keychains/login.keychain-db

echo "Building (about a minute)…"
log="$build/xcodebuild.log"
cd "$pocket/ios/App"
xcodebuild -project App.xcodeproj -scheme App -configuration Debug -allowProvisioningUpdates \
  -destination "id=$DEVICE" -derivedDataPath "$build/dd" \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_ENTITLEMENTS="$ent" build > "$log" 2>&1 \
  || { grep -E "errSec|error:" "$log" | cut -c1-200; echo "BUILD FAILED (log: $log)"; exit 1; }

echo "Installing…"
xcrun devicectl device install app --device "$DEVICE" "$build/dd/Build/Products/Debug-iphoneos/App.app"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" \
  || echo "Installed. If it didn't open: Settings → General → VPN & Device Management → trust your developer profile."
