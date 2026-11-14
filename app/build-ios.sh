#!/bin/sh
# Builds the signed App Store package (.ipa) for Operation Windfall.
# Needs Xcode with the developer account signed in (team ZP6DN8JZX7).
# Before a new upload, raise CURRENT_PROJECT_VERSION (and MARKETING_VERSION for a new version)
# in ios/App/App.xcodeproj/project.pbxproj.
set -e
cd "$(dirname "$0")"
export LANG=en_US.UTF-8
npm run sync
cd ios/App
rm -rf build/OperationWindfall.xcarchive build/export
# Archive unsigned: signing an archive would need a development profile and a registered device.
xcodebuild -project App.xcodeproj -scheme App -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/OperationWindfall.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" archive
cat > build/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>ZP6DN8JZX7</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
# The export step signs with the Apple Distribution certificate and an App Store profile.
xcodebuild -exportArchive -archivePath build/OperationWindfall.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates
echo "Package: $(pwd)/build/export/App.ipa"
