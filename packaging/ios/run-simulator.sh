#!/bin/bash
# Installs and launches the simulator build of the iPhone app.
# Run it from the desktop account so the Simulator window shows up.
# The build itself (dist/ios/DerivedData) has to exist already.
# Usage: run-simulator.sh ["simulator name"]   (default "iPhone 17")
set -euo pipefail
cd "$(dirname "$0")/../.."
DEVICE=${1:-iPhone 17}
APP=$PWD/dist/ios/DerivedData/Build/Products/Debug-iphonesimulator/ServerManager.app
# xcode-select points at the Command Line Tools, which have no simctl.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if [ ! -d "$APP" ]; then
	echo "No simulator build at $APP" >&2
	exit 1
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

echo "== Booting $DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
open -a Simulator

echo "== Installing and launching"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID"
