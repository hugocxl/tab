#!/bin/sh
# Archive the app and upload it to App Store Connect for TestFlight, signed
# with the account Xcode is logged in to. The version is CHANGELOG.md's (shared
# with the Mac app) and the build number the commit count, so every commit
# uploads once.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$(git -C "$ROOT" rev-list --count HEAD)
VERSION_SETTINGS=$("$ROOT/scripts/version.sh")
ARCHIVE="$ROOT/.build/release/Tab.xcarchive"
OPTIONS="$ROOT/.build/release/ExportOptions.plist"

rm -rf "$ROOT/.build/release"
mkdir -p "$ROOT/.build/release"

echo "== Archive (build $BUILD)"
xcodebuild archive -project "$ROOT/App/Tab.xcodeproj" -scheme Tab -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/.build/app-release" \
    -allowProvisioningUpdates -quiet $VERSION_SETTINGS

cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>JFMWLVS6WR</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>testFlightInternalTestingOnly</key>
	<false/>
</dict>
</plist>
EOF

echo "== Upload"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "$ROOT/.build/release/export" -allowProvisioningUpdates

echo "Uploaded build $BUILD. It shows in TestFlight once App Store Connect has processed it."
