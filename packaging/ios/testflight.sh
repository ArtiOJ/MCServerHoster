#!/bin/bash
# Builds the signed iPhone app for TestFlight, dist/testflight/export/ServerManager.ipa:
# exports the release Xcode project with Godot, archives it, and signs it with the
# Apple Distribution certificate from a throwaway keychain, so any account that can
# read the files below can run it. Needs Xcode 26 and Godot 4.7.2 (GODOT).
#   testflight.sh                        build and sign
#   testflight.sh --validate             ... then have Apple check it
#   testflight.sh --validate --upload    ... then send it to App Store Connect
# Settings come from the environment, then from the git-ignored .env at the root:
#   APPLE_TEAM_ID       the team the certificate and the profile belong to
#   APPLE_P12_FILE      the Apple Distribution certificate with its key
#   APPLE_P12_PASSWORD  the password it was exported with
#   ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_FILE   the App Store Connect
#                       API key, for --validate and --upload
# The profile is secrets/Server_Manager_App_Store.mobileprovision, made by
# `python3 packaging/ios/asc.py setup`. The build number is the commit count.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
GODOT=${GODOT:-godot}
OUT=$ROOT/dist/testflight
PROFILE=$ROOT/secrets/Server_Manager_App_Store.mobileprovision

DO_VALIDATE=no
DO_UPLOAD=no
for arg in "$@"; do
	case "$arg" in
		--validate) DO_VALIDATE=yes ;;
		--upload) DO_UPLOAD=yes ;;
		*) echo "Usage: testflight.sh [--validate] [--upload]" >&2; exit 1 ;;
	esac
done

die() { echo "testflight.sh: $*" >&2; exit 1; }
setting() {
	local value=${!1:-}
	if [ -z "$value" ] && [ -r .env ]; then
		value=$(sed -n "s/^$1=//p" .env | head -1)
	fi
	[ -n "$value" ] || die "$1 is not set (environment or $ROOT/.env)"
	printf '%s' "$value"
}

# xcode-select may point at the Command Line Tools, which have no iOS SDK.
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

TEAM=$(setting APPLE_TEAM_ID)
P12=$(setting APPLE_P12_FILE)
P12_PASSWORD=$(setting APPLE_P12_PASSWORD)
if [ $DO_VALIDATE = yes ] || [ $DO_UPLOAD = yes ]; then
	ASC_KEY=$(setting ASC_API_KEY_ID)
	ASC_ISSUER=$(setting ASC_API_ISSUER_ID)
	ASC_KEY_FILE=$(setting ASC_API_KEY_FILE)
fi
BUNDLE_ID=$(sed -n 's/^application\/bundle_identifier="\(.*\)"/\1/p' export_presets.cfg)
VERSION=$(sed -n 's/^application\/short_version="\(.*\)"/\1/p' export_presets.cfg)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}

echo "== Checking the profile"
[ -f "$PROFILE" ] || die "no $PROFILE; run: python3 packaging/ios/asc.py setup"
rm -rf "$OUT"
mkdir -p "$OUT"
security cms -D -i "$PROFILE" > "$OUT/profile.plist"
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$OUT/profile.plist")
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$OUT/profile.plist")
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$OUT/profile.plist")
[ "$APP_ID" = "$TEAM.$BUNDLE_ID" ] || die "the profile is for $APP_ID, not $TEAM.$BUNDLE_ID"
# Xcode 26 looks for profiles here, by UUID.
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES_DIR"
cp "$PROFILE" "$PROFILES_DIR/$PROFILE_UUID.mobileprovision"

echo "== Signing keychain"
# codesign builds the chain from the login and System keychains, so Apple's
# WWDR G3 intermediate has to be there, not just in the throwaway keychain.
security find-certificate -a -Z -c "Apple Worldwide Developer Relations Certification Authority" 2>/dev/null \
	| grep -q DCF21878C77F4198E4B4614F03D696D89C66C66008D4244E1B99161AAC91601F \
	|| die "Apple's WWDR G3 intermediate is not in $(id -un)'s keychains." \
		"Get AppleWWDRCAG3.cer from https://www.apple.com/certificateauthority/ and" \
		"security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db"
KC_DIR=$(mktemp -d -t servermanager-keychain)
KC=$KC_DIR/signing.keychain-db
KC_PASSWORD=$(openssl rand -hex 24)
OLD_KEYCHAINS=$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
restore_keychains() {
	echo "$OLD_KEYCHAINS" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s 2>/dev/null || true
	security delete-keychain "$KC" 2>/dev/null || true
	rm -rf "$KC_DIR"
}
trap restore_keychains EXIT
security create-keychain -p "$KC_PASSWORD" "$KC"
security set-keychain-settings -lut 7200 "$KC"
security unlock-keychain -p "$KC_PASSWORD" "$KC"
security import "$P12" -k "$KC" -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASSWORD" "$KC" >/dev/null
echo "$OLD_KEYCHAINS" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s "$KC"
security find-identity -v -p codesigning "$KC" | grep -q "Apple Distribution: .*($TEAM)" \
	|| die "$P12 holds no valid Apple Distribution identity for team $TEAM"

echo "== Exporting the Xcode project ($VERSION, build $BUILD_NUMBER)"
"$GODOT" --headless --path . -s packaging/make_icons.gd -- "$ROOT/packaging/build" >/dev/null 2>&1
test -f packaging/build/app-icon-1024.png
# With a profile named here, Godot writes the release configuration as manual signing.
GODOT_APPLE_PLATFORM_PROFILE_SPECIFIER_RELEASE=$PROFILE_NAME \
	"$GODOT" --headless --path . --export-release "iOS" "$OUT/ServerManager.ipa" > "$OUT/export.log" 2>&1 \
	|| { tail -20 "$OUT/export.log"; die "the Godot export failed ($OUT/export.log)"; }
test -d "$OUT/ServerManager.xcodeproj"

echo "== Archiving"
xcodebuild -project "$OUT/ServerManager.xcodeproj" -scheme ServerManager -configuration Release \
	-destination generic/platform=iOS -archivePath "$OUT/ServerManager.xcarchive" \
	-derivedDataPath "$OUT/DerivedData" \
	CURRENT_PROJECT_VERSION="$BUILD_NUMBER" OTHER_CODE_SIGN_FLAGS="--keychain $KC" \
	archive > "$OUT/archive.log" 2>&1 \
	|| { grep -E 'error:|warning: .*sign' "$OUT/archive.log" | tail -20; die "the archive failed ($OUT/archive.log)"; }

echo "== Exporting the .ipa"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string></dict>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/ServerManager.xcarchive" -exportPath "$OUT/export" \
	-exportOptionsPlist "$OUT/ExportOptions.plist" > "$OUT/export-ipa.log" 2>&1 \
	|| { grep -E 'error' "$OUT/export-ipa.log" | tail -20; die "the .ipa export failed ($OUT/export-ipa.log)"; }
IPA=$OUT/export/ServerManager.ipa
test -f "$IPA"
echo "Built $IPA"

altool() {
	xcrun altool "$@" -t ios --api-key "$ASC_KEY" --api-issuer "$ASC_ISSUER" --p8-file-path "$ASC_KEY_FILE"
}
if [ $DO_VALIDATE = yes ]; then
	echo "== Validating with Apple"
	altool --validate-app -f "$IPA"
fi
if [ $DO_UPLOAD = yes ]; then
	echo "== Uploading to App Store Connect"
	altool --upload-app -f "$IPA"
	echo "Apple processes the build for a few minutes; python3 packaging/ios/asc.py builds shows when it is VALID."
fi
