#!/bin/bash
set -euo pipefail

APP_NAME="Claude Usage Counter"
VERSION="1.5.0"
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

# Create dmg from staging directory (UDZO = compressed).
# `hdiutil create -srcfolder` sometimes fails with "Resource busy" (diskimages-helper
# can't attach its scratch device). Fall back to makehybrid, which builds the HFS
# image without attaching anything, then compress it with convert.
if ! hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${DMG_PATH}" >/dev/null; then
    echo "⚠️  hdiutil create failed — falling back to makehybrid + convert..."
    TMP_DMG="${BUILD_DIR}/tmp-hybrid.dmg"
    rm -f "${TMP_DMG}" "${DMG_PATH}"
    hdiutil makehybrid -hfs -hfs-volume-name "${VOLUME_NAME}" \
        -o "${TMP_DMG}" "${STAGING_DIR}" >/dev/null
    hdiutil convert "${TMP_DMG}" -format UDZO -o "${DMG_PATH}" >/dev/null
    rm -f "${TMP_DMG}"
fi

hdiutil verify "${DMG_PATH}" >/dev/null 2>&1 || { echo "❌ DMG verification failed"; exit 1; }

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
