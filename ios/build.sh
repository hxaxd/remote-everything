#!/bin/sh
set -eu

team_id=${1:?Apple development team ID required}
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
command -v xcodegen >/dev/null
xcodegen generate
mkdir -p build
xcodebuild \
  -project AgentRemote.xcodeproj \
  -scheme AgentRemote \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$root/build/AgentRemote.xcarchive" \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  archive

printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' \
  '<dict>' \
  '<key>method</key><string>development</string>' \
  '<key>signingStyle</key><string>automatic</string>' \
  "<key>teamID</key><string>$team_id</string>" \
  '</dict>' \
  '</plist>' > "$root/build/ExportOptions.plist"

xcodebuild \
  -exportArchive \
  -archivePath "$root/build/AgentRemote.xcarchive" \
  -exportPath "$root/build/export" \
  -exportOptionsPlist "$root/build/ExportOptions.plist" \
  -allowProvisioningUpdates
