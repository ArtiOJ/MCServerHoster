#!/bin/bash
# Builds the release packages into dist/:
#   server-manager-<ver>-x86_64.pkg.tar.zst   Arch Linux package (needs makepkg)
#   server-manager-<ver>-linux-x86_64.tar.gz  plain Linux build
#   ServerManager-<ver>-setup.exe             Windows 10/11 installer (needs makensis)
#   ServerManager-<ver>-windows-x86_64.zip    portable Windows build
# Needs Godot 4.7.2 with its export templates.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
GODOT=${GODOT:-godot}
VERSION=$(sed -n 's/^config\/version="\(.*\)"/\1/p' project.godot)
DIST=$ROOT/dist
BUILD=$ROOT/packaging/build
rm -rf "$DIST" "$BUILD"
mkdir -p "$DIST/linux" "$DIST/windows" "$BUILD"

echo "== Icons"
"$GODOT" --headless --path . -s packaging/make_icons.gd -- "$BUILD" >/dev/null 2>&1
test -f "$BUILD/server-manager.ico"

echo "== Exporting Linux and Windows builds ($VERSION)"
"$GODOT" --headless --path . --export-release "Linux" "$DIST/linux/server-manager"
"$GODOT" --headless --path . --export-release "Windows" "$DIST/windows/ServerManager.exe"

echo "== Linux tarball"
STAGE=$BUILD/server-manager
mkdir -p "$STAGE"
cp "$DIST/linux/server-manager" "$STAGE/"
cp packaging/server-manager.desktop "$STAGE/"
cp icon.svg "$STAGE/server-manager.svg"
cp "$BUILD/server-manager-256.png" LICENSE "$STAGE/"
TARBALL=server-manager-$VERSION-linux-x86_64.tar.gz
tar -C "$BUILD" -czf "$DIST/$TARBALL" server-manager

echo "== Arch package"
if command -v makepkg >/dev/null; then
	ARCH=$BUILD/arch
	mkdir -p "$ARCH"
	sed "s/^pkgver=.*/pkgver=$VERSION/" packaging/arch/PKGBUILD > "$ARCH/PKGBUILD"
	cp "$DIST/$TARBALL" "$ARCH/"
	(cd "$ARCH" && PKGDEST="$DIST" makepkg -f --nodeps >/dev/null)
else
	echo "makepkg not found; skipping the Arch package"
fi

echo "== Windows"
WIN=$BUILD/windows
mkdir -p "$WIN"
cp "$DIST/windows/ServerManager.exe" "$BUILD/server-manager.ico" "$WIN/"
sed 's/$/\r/' LICENSE > "$WIN/LICENSE.txt"
bsdtar -C "$WIN" -a -cf "$DIST/ServerManager-$VERSION-windows-x86_64.zip" ServerManager.exe LICENSE.txt
if command -v makensis >/dev/null; then
	makensis -V2 -DVERSION="$VERSION" -DSOURCE="$WIN" -DOUTFILE="$DIST/ServerManager-$VERSION-setup.exe" packaging/windows/installer.nsi
else
	echo "makensis not found; skipping the Windows installer (sudo pacman -S nsis)"
fi
rm -rf "$DIST/linux" "$DIST/windows"
echo "== Done"
ls -lh "$DIST"
