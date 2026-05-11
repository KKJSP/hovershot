#!/usr/bin/env bash
# Build the HoverShot.app bundle without Xcode.
# Compiles every .swift in Sources/ and lays out a runnable .app under build/.
#
# Usage:
#   ./build.sh              persistent self-signed identity (recommended)
#   ./build.sh --ad-hoc     skip the keychain step; sign ad-hoc only
#   ./build.sh -h           show this help
#
# Persistent signing keeps the app's Designated Requirement stable across
# rebuilds, which is what allows macOS to remember the Accessibility / Screen
# Recording grants you've approved. Ad-hoc signing still produces a runnable
# .app, but its hash changes every build so macOS treats it as a new app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HoverShot"
BUNDLE_ID="com.hovershot.app.HoverShot"
SIGN_CN="hovershot-cert"
BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

AD_HOC=0
for arg in "$@"; do
    case "$arg" in
        --ad-hoc|--adhoc) AD_HOC=1 ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Run with -h for usage." >&2
            exit 1
            ;;
    esac
done

# 1. Resolve a signing identity.
#    Persistent default: invoke setup-signing.sh on the first build so TCC
#    permissions survive subsequent rebuilds. With --ad-hoc, skip the keychain
#    work entirely and let the codesign step below fall through to ad-hoc.
if [ "$AD_HOC" -eq 0 ]; then
    if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_CN"; then
        echo "==> No persistent signing identity yet."
        echo "    Running setup-signing.sh to create one — macOS may prompt for your"
        echo "    login password. Pass --ad-hoc to skip this step."
        if ! bash "${ROOT}/setup-signing.sh"; then
            echo
            echo "==> Persistent signing setup failed; falling back to ad-hoc."
            AD_HOC=1
        fi
    fi
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

SWIFT_FILES=()
while IFS= read -r -d '' f; do
    SWIFT_FILES+=("$f")
done < <(find "${ROOT}/Sources" -name "*.swift" -print0)

echo "==> Compiling ${#SWIFT_FILES[@]} Swift files"
xcrun swiftc \
    -O \
    -target arm64-apple-macos11.0 \
    -framework AppKit \
    -framework Vision \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -framework Accelerate \
    -o "${MACOS_DIR}/${APP_NAME}" \
    "${SWIFT_FILES[@]}"

echo "==> Copying resources"
cp "${ROOT}/Resources/Info.plist"      "${APP_DIR}/Contents/Info.plist"
cp "${ROOT}/Resources/AppIcon.icns"    "${RES_DIR}/AppIcon.icns"
cp "${ROOT}/Resources/MenuBarIcon.png" "${RES_DIR}/MenuBarIcon.png"
echo "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# 2. Sign with the stable identity if we have it; otherwise ad-hoc so the
#    bundle still launches.
if [ "$AD_HOC" -eq 0 ] && security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_CN"; then
    echo "==> Signing with '$SIGN_CN'"
    codesign --force --deep \
        --sign "$SIGN_CN" \
        --identifier "$BUNDLE_ID" \
        "${APP_DIR}" >/dev/null
else
    echo "==> Signing ad-hoc (permissions will reset between builds)"
    codesign --force --deep --sign - "${APP_DIR}" >/dev/null
fi

# Bump mtime + re-register with LaunchServices so Finder picks up the bundle
# icon instead of any cached blank glyph from a prior build.
touch "${APP_DIR}"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREG" ]; then
    "$LSREG" -f "${APP_DIR}" >/dev/null 2>&1 || true
fi

echo "==> Creating ZIP archive"
(cd "${BUILD_DIR}" && zip -r -q "${APP_NAME}.app.zip" "${APP_NAME}.app")

echo
echo "Built: ${APP_DIR}"
echo "ZIP:   ${BUILD_DIR}/${APP_NAME}.app.zip"
echo "Run with:  open \"${APP_DIR}\""
