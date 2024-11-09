#!/usr/bin/env bash

# Required tools:
# - curl or wget or aria2c
# - find
# - sed

set -e


ARCH=$(uname -m)
ARCH_ALT=$ARCH
case $ARCH in
  x86_64);;
  aarch64|arm64)ARCH=arm64;;
  *)printf "Unsupported arch: %s\n" "$ARCH"; exit 1;;
esac

URL_APPIMAGETOOL=https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH_ALT.AppImage
URL_YUI_FIDDLER=https://github.com/project-yui/Yui-patch/releases/download/continuous/yui-libfiddler-linux-$ARCH-continuous.so
URL_YUI_OPEN=https://github.com/project-yui/Yui-patch/releases/download/continuous/yui-libopen-linux-$ARCH-continuous.so
URL_FIDDLER_ENHANCE=https://github.com/msojocs/fiddler-everywhere-enhance/archive/refs/heads/main.tar.gz
URL_FIDDLER_LATEST=https://api.getfiddler.com/linux/latest-linux

has_prog() {
  command -v "$1" > /dev/null
}

download_direct() {
  local link=$1
  local target=$2
  if has_prog aria2c; then
    # NOTE: aria2c does not support absolute path
    aria2c -o "$target" "$link"
  elif has_prog curl; then
    curl -fsSL -o "$target" "$link"
  elif has_prog wget; then
    wget -O "$target" "$link"
  else
    return 1
  fi
}

download_with_partial() {
  local link=$1
  local target=$2
  if download_direct "$link" "$target.partial"; then
    mv "$target.partial" "$target"
  else
    return $?
  fi
}

download_overwrite() {
  local link=$1
  local target=$2
  if [ -f "$target" ]; then
    rm -f "$target"
  fi
  download_with_partial "$link" "$target"
}

download_if_not_found() {
  local link=$1
  local target=$2
  if [ -f "$target" ]; then
    return
  fi
  download_with_partial "$link" "$target"
}

LIBFID=yui-libfiddler.so
LIBOPEN=yui-libopen.so
ENHANCE_DIR=fiddler-everywhere-enhance

download_overwrite "$URL_YUI_FIDDLER" "$LIBFID"
download_overwrite "$URL_YUI_OPEN" "$LIBOPEN"
download_overwrite "$URL_FIDDLER_ENHANCE" "fiddler-enhance.tar.gz"
download_overwrite "$URL_FIDDLER_LATEST" "fiddler-latest.AppImage"

mkdir -p "$ENHANCE_DIR"
tar xf "fiddler-enhance.tar.gz" --strip-components=1 -C "$ENHANCE_DIR"

LIBFID=$(readlink -f "$LIBFID")
LIBOPEN=$(readlink -f "$LIBOPEN")
ENHANCE_DIR=$(readlink -f "$ENHANCE_DIR")

# FIXME: RCE issue here
chmod +x "fiddler-latest.AppImage"
# remove old files
[ ! -d squashfs-root ] || rm -rf squashfs-root
./fiddler-latest.AppImage --appimage-extract # now we have squashfs-root, per spec

### Patching start
pushd squashfs-root

cp "$LIBFID" libfiddler.so
cp "$LIBOPEN" resources/app/out/WebServer/libopen.so

mv resources/app/out/WebServer/Fiddler.WebUi resources/app/out/WebServer/Fiddler.WebUi.original
cat << EOF > resources/app/out/WebServer/Fiddler.WebUi
#!/bin/bash
export LD_PRELOAD=./libopen.so
./Fiddler.WebUi.original \$@
EOF

chmod +x resources/app/out/WebServer/Fiddler.WebUi

FILE_MAINJS_SUB=$(find . -name "main-*.js")
if [ ! -f "$FILE_MAINJS_SUB" ]; then
  echo "Missing main-XXXXXXXX.js, not supported, abort!"
  exit 1
fi

SERIAL=$FILE_MAINJS_SUB
SERIAL=${SERIAL##*main-}
SERIAL=${SERIAL%.js}
cat << EOF > resources/app/out/WebServer/patch.json
{
    "ClientApp/dist/main-$SERIAL.js": {
        "target": "ClientApp/dist/main-$SERIAL.original.js",
        "content": "",
        "cur": 0,
        "start": 0,
        "end": 1
    },
    "../main.js": {
        "target": "../main.original.js",
        "content": "",
        "cur": 0,
        "start": 0,
        "end": 1
    }
}
EOF

TARGET=${FILE_MAINJS_SUB%.js}.original.js
cp "$FILE_MAINJS_SUB" "$TARGET"
cp "resources/app/out/main.js" "resources/app/out/main.original.js" 

cat "$ENHANCE_DIR/server/index.js" resources/app/out/main.original.js > resources/app/out/main.js

sed -i "s|https://api.getfiddler.com|http://127.0.0.1:5678/api.getfiddler.com|g" "$FILE_MAINJS_SUB"
sed -i "s|https://identity.getfiddler.com|http://127.0.0.1:5678/identity.getfiddler.com|g" "$FILE_MAINJS_SUB"

cp -r "$ENHANCE_DIR/server/file" resources/app/out/

popd

### Patching end, now repacking

# FIXME: oops, more RCE
download_if_not_found "$URL_APPIMAGETOOL" "appimagetool.AppImage"
chmod +x "appimagetool.AppImage"

./appimagetool.AppImage squashfs-root Fiddler_Enhanced.AppImage
chmod +x Fiddler_Enhanced.AppImage

echo "Done! See Fiddler_Enhanced.AppImage"
