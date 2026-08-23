#!/bin/bash
# Cut a release: bump the version, build the Linux artifacts, report what
# came out.
#
#   ./release.sh              patch bump (2.0.0 -> 2.0.1)
#   ./release.sh minor        2.0.0 -> 2.1.0
#   ./release.sh major        2.0.0 -> 3.0.0
#   ./release.sh --no-bump    build the current version as-is
#
# The version lives in two places that have to agree: VERSION in the
# Makefile (names the artifacts) and APP_VERSION in main.odin (what the
# About tab shows). This bumps both.
#
# Windows builds are not produced here — SDL3 and Vulkan link through
# MSVC import libraries, so that half has to run on Windows. See BUILD.md.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="er-boss-checklist"
ARCH="amd64"
MAKEFILE="Makefile"
VERSION_SOURCE="main.odin"

# ----------------------------------------------------------------------------
# Work out the new version
# ----------------------------------------------------------------------------

BUMP="${1:-patch}"

OLD_VERSION=$(grep '^VERSION *:=' "$MAKEFILE" | awk '{print $3}')
[ -n "$OLD_VERSION" ] || { echo "Could not read VERSION from $MAKEFILE"; exit 1; }

# main.odin is the one users actually see, so a mismatch is worth catching
# before it ships rather than after.
ODIN_VERSION=$(grep '^APP_VERSION *::' "$VERSION_SOURCE" | sed 's/.*"\(.*\)".*/\1/')
if [ "$ODIN_VERSION" != "$OLD_VERSION" ]; then
    echo "Version mismatch before bumping:"
    echo "  $MAKEFILE:        $OLD_VERSION"
    echo "  $VERSION_SOURCE:  $ODIN_VERSION"
    echo "Fix one of them so they agree, then re-run."
    exit 1
fi

if [ "$BUMP" = "--no-bump" ]; then
    NEW_VERSION="$OLD_VERSION"
    echo "=== Release: ${NEW_VERSION} (no bump) ==="
else
    IFS='.' read -r MAJOR MINOR PATCH <<< "$OLD_VERSION"
    case "$BUMP" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
        *)     echo "Usage: $0 [major|minor|patch|--no-bump]"; exit 1 ;;
    esac
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    echo "=== Release: ${OLD_VERSION} -> ${NEW_VERSION} (${BUMP}) ==="
fi
echo ""

if [ "$NEW_VERSION" != "$OLD_VERSION" ]; then
    sed -i "s/^VERSION *:= ${OLD_VERSION}/VERSION  := ${NEW_VERSION}/" "$MAKEFILE"
    sed -i "s/^APP_VERSION :: \"${OLD_VERSION}\"/APP_VERSION :: \"${NEW_VERSION}\"/" "$VERSION_SOURCE"
    echo "[1/4] Bumped $MAKEFILE and $VERSION_SOURCE to ${NEW_VERSION}"
else
    echo "[1/4] Version left at ${NEW_VERSION}"
fi

# ----------------------------------------------------------------------------
# Build
#
# `make tar` bundles libSDL3.so.0 next to the binary so the archive runs on
# distros without an SDL3 package (Ubuntu 24.04, Debian 12). `make deb`
# declares the dependency instead and lets apt handle it.
# ----------------------------------------------------------------------------

echo "[2/4] Building portable Linux archive..."
make tar > /dev/null
TAR_FILE="${APP_NAME}_${NEW_VERSION}_linux.tar.gz"

echo "[3/4] Building .deb package..."
make deb > /dev/null
DEB_FILE="${APP_NAME}_${NEW_VERSION}_${ARCH}.deb"

# Optional extra: .7z alongside, for anywhere that wants the smaller file.
ARTIFACTS=("$TAR_FILE" "$DEB_FILE")
if command -v 7z > /dev/null; then
    rm -f "${DEB_FILE}.7z"
    7z a "${DEB_FILE}.7z" "$DEB_FILE" > /dev/null
    ARTIFACTS+=("${DEB_FILE}.7z")
fi

echo "[4/4] Cleaning up build directories..."
rm -rf "${APP_NAME}_${NEW_VERSION}_linux" "${APP_NAME}_${NEW_VERSION}_${ARCH}"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

echo ""
echo "=== Release ${NEW_VERSION} built ==="
echo ""
ls -lh "${ARTIFACTS[@]}"
echo ""
echo "Still to do by hand:"
if [ "$NEW_VERSION" != "$OLD_VERSION" ]; then
    echo "  * commit the version bump:  git commit -am \"Release ${NEW_VERSION}\""
    echo "  * tag it:                   git tag v${NEW_VERSION}"
fi
echo "  * build the Windows zip on a Windows machine (see BUILD.md)"
echo "  * both the .deb and the .tar.gz carry SDL3, so neither needs a system one"
