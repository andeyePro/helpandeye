#!/bin/sh
# Builds the Help&I box firmware: MeshCore at a pinned commit, with firmware/box and
# firmware/core copied in as an overlay, built by PlatformIO.
#
#   firmware/build.sh [--release] [build dir] [environment]
#
# The build directory holds one MeshCore checkout, reused on every run (default: ./build/meshcore).
# The environment is heltec_v4_helpandi (the box) or heltec_v4_helpandi_dev (a plain board with
# only its PRG button). Needs git and PlatformIO (`pio`; for example
# `python3 -m pip install --user platformio`, which puts it in ~/Library/Python/3.*/bin on a Mac).
#
# --release is for a box that goes to a home (firmware/DESIGN.md, section 16): the same image,
# then signed for secure boot v2 and encrypted for flash encryption with keys that live outside
# any repository, in the directory HI_RELEASE_KEYS (secure_boot_signing_key.pem and
# flash_encryption_key.bin). Without HI_RELEASE_KEYS it builds and prints every step instead.
# It never touches a board: the eFuse and flash commands are printed for a person to run.
set -eu

MESHCORE_REPO=https://github.com/meshcore-dev/MeshCore
MESHCORE_COMMIT=81dbae592ffad40b4212bc0b37e82b38da08f4bc   # 15 October 2026, as firmware/DESIGN.md cites

release=0
if [ "${1:-}" = "--release" ]; then
  release=1
  shift
fi
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
out="$tree/.pio/build/$env"
echo "Built $env: $out/firmware.bin"
[ "$release" = 1 ] || exit 0

# Release: sign, then encrypt, with esptool's own tools from PlatformIO's package.
core=${PLATFORMIO_CORE_DIR:-$HOME/.platformio}
python=$(pio system info --json-output | python3 -c 'import json, sys; print(json.load(sys.stdin)["python_exe"]["value"])')
espsecure="$python $core/packages/tool-esptoolpy/espsecure.py"
bootapp0="$core/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
keys=${HI_RELEASE_KEYS:-}
rel="$out/release"
mkdir -p "$rel"

if [ -z "$keys" ]; then
  echo "Release dry run: HI_RELEASE_KEYS is not set, so nothing is signed or encrypted. The steps:"
  if ! $espsecure version >/dev/null 2>&1; then
    echo "  (espsecure.py cannot run with PlatformIO's python here: it needs esptool's 'cryptography' module)"
  fi
  keys='$HI_RELEASE_KEYS'
  run() { echo "  $*"; }
else
  for k in secure_boot_signing_key.pem flash_encryption_key.bin; do
    [ -f "$keys/$k" ] || { echo "Missing $keys/$k" >&2; exit 1; }
  done
  run() { echo "+ $*"; "$@"; }
fi

run $espsecure sign_data --version 2 --keyfile "$keys/secure_boot_signing_key.pem" \
  --output "$rel/bootloader-signed.bin" "$out/bootloader.bin"
run $espsecure sign_data --version 2 --keyfile "$keys/secure_boot_signing_key.pem" \
  --output "$rel/firmware-signed.bin" "$out/firmware.bin"
# Each image is encrypted for the address it is flashed at (XTS-AES ties the bytes to it).
run $espsecure encrypt_flash_data --aes_xts --keyfile "$keys/flash_encryption_key.bin" \
  --address 0x0 --output "$rel/bootloader.bin" "$rel/bootloader-signed.bin"
run $espsecure encrypt_flash_data --aes_xts --keyfile "$keys/flash_encryption_key.bin" \
  --address 0x8000 --output "$rel/partitions.bin" "$out/partitions.bin"
run $espsecure encrypt_flash_data --aes_xts --keyfile "$keys/flash_encryption_key.bin" \
  --address 0xe000 --output "$rel/boot_app0.bin" "$bootapp0"
run $espsecure encrypt_flash_data --aes_xts --keyfile "$keys/flash_encryption_key.bin" \
  --address 0x10000 --output "$rel/firmware.bin" "$rel/firmware-signed.bin"

cat <<EOF
Release images in $rel: bootloader.bin, partitions.bin, boot_app0.bin and firmware.bin are
encrypted for their addresses; firmware-signed.bin is the signed, unencrypted image for a field
update over the air. For each box, by hand (DESIGN.md section 16; these burn eFuses and cannot
be undone):
  python3 \$ESPTOOL/esptool.py --chip esp32s3 --port PORT write_flash 0x0 $rel/bootloader.bin \\
    0x8000 $rel/partitions.bin 0xe000 $rel/boot_app0.bin 0x10000 $rel/firmware.bin
  python3 \$ESPTOOL/espefuse.py --chip esp32s3 --port PORT burn_key BLOCK_KEY0 \\
    \$HI_RELEASE_KEYS/flash_encryption_key.bin XTS_AES_128_KEY
  python3 \$ESPTOOL/espefuse.py --chip esp32s3 --port PORT burn_key_digest BLOCK_KEY1 \\
    \$HI_RELEASE_KEYS/secure_boot_signing_key.pem SECURE_BOOT_DIGEST0
  python3 \$ESPTOOL/espefuse.py --chip esp32s3 --port PORT burn_efuse SECURE_BOOT_EN 1 \\
    SECURE_BOOT_KEY_REVOKE1 1 SECURE_BOOT_KEY_REVOKE2 1 SPI_BOOT_CRYPT_CNT 7 \\
    DIS_DOWNLOAD_MANUAL_ENCRYPT 1 DIS_DOWNLOAD_ICACHE 1 DIS_DOWNLOAD_DCACHE 1 \\
    DIS_DIRECT_BOOT 1 DIS_USB_JTAG 1 HARD_DIS_JTAG 1 ENABLE_SECURITY_DOWNLOAD 1
EOF
