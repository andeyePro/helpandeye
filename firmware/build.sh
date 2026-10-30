#!/bin/sh
# Builds the Help&I box firmware: MeshCore at a pinned commit, with firmware/box and
# firmware/core copied in as an overlay, built by PlatformIO.
#
#   firmware/build.sh [build dir] [environment]
#
# The build directory holds one MeshCore checkout, reused on every run (default: ./build/meshcore).
# The environment is heltec_v4_helpandi (the box) or heltec_v4_helpandi_dev (a plain board with
# only its PRG button). Needs git and PlatformIO (`pio`; for example
# `python3 -m pip install --user platformio`, which puts it in ~/Library/Python/3.*/bin on a Mac).
set -eu

MESHCORE_REPO=https://github.com/meshcore-dev/MeshCore
MESHCORE_COMMIT=81dbae592ffad40b4212bc0b37e82b38da08f4bc   # 15 October 2026, as firmware/DESIGN.md cites

here=$(cd "$(dirname "$0")" && pwd)
tree=${1:-"$here/build/meshcore"}
env=${2:-heltec_v4_helpandi}

if [ ! -d "$tree/.git" ]; then
  git clone "$MESHCORE_REPO" "$tree"
fi
git -C "$tree" fetch -q origin
git -C "$tree" checkout -q --force "$MESHCORE_COMMIT"
git -C "$tree" clean -q -fd examples/companion_radio/ui-helpandi 2>/dev/null || true

# The overlay: the UI task and the portable core, the PlatformIO environments, and one small
# patch giving the UI task the companion commands MeshCore does not know.
ui="$tree/examples/companion_radio/ui-helpandi"
rm -rf "$ui"
mkdir -p "$ui/core"
cp "$here"/box/ui-helpandi/* "$ui/"
cp "$here"/core/*.hpp "$here"/core/*.cpp "$ui/core/"
cp "$here/box/platformio.local.ini" "$tree/platformio.local.ini"
git -C "$tree" apply "$here/box/meshcore.patch"

cd "$tree"
pio run -e "$env"
echo "Built $env: $tree/.pio/build/$env/firmware.bin"
