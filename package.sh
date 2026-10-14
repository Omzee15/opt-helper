#!/bin/zsh
# Makes OptHelper.dmg next to this script: the app plus an Applications shortcut to drag it onto.
# With a "Developer ID Application" certificate and a notarytool profile
# (xcrun notarytool store-credentials opthelper-notary ...), also notarizes and staples it,
# so it opens on other Macs without any warnings. NOTARY_PROFILE overrides the profile name.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DMG=OptHelper.dmg
STAGE=$(mktemp -d)
cp -R OptHelper.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname OptHelper -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
PROFILE=${NOTARY_PROFILE:-opthelper-notary}
if [[ -n "$ID" ]]; then
  codesign --force --sign "$ID" "$DMG"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Built $DMG — notarized, ready to share."
    exit 0
  fi
  echo "Built $DMG — signed with Developer ID but NOT notarized (no '$PROFILE' notarytool profile)."
else
  echo "Built $DMG — NOT notarized (no Developer ID certificate). Recipients must allow it once in System Settings › Privacy & Security."
fi
