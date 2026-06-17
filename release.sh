#!/bin/bash
set -euo pipefail

APP_NAME="Claude Usage Counter"
VERSION="1.2.0"
BUILD_DIR="build"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
DMG_NAME="ClaudeUsageCounter-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
STAGING_DIR="${BUILD_DIR}/dmg-staging"
VOLUME_NAME="Claude Usage Counter ${VERSION}"

if [ ! -d "${APP_PATH}" ]; then
    echo "❌ App not found. Running build first..."
    ./build.sh
fi

echo "💿 Creating ${DMG_NAME}..."

# Clean staging
rm -rf "${STAGING_DIR}"
rm -f  "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"

# Copy app + Applications shortcut into staging
cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# Create dmg from staging directory
# UDZO = compressed, OVERWRITE if exists
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${DMG_PATH}" >/dev/null

# Cleanup
rm -rf "${STAGING_DIR}"

# Show output info
SIZE=$(du -h "${DMG_PATH}" | cut -f1)
SHA=$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)

echo ""
echo "✅ Created: ${DMG_PATH} (${SIZE})"
echo "   SHA256:  ${SHA}"
echo ""
echo "To open: open \"${DMG_PATH}\""
