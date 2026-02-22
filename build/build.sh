#!/bin/bash

# Remove old builds
rm -rf dist build

# Make the large icon set
mkdir icon.iconset

sips -z 16 16   ./icon/icon.png --out icon.iconset/icon_16x16.png
sips -z 32 32   ./icon/icon.png --out icon.iconset/icon_16x16@2x.png
sips -z 32 32   ./icon/icon.png --out icon.iconset/icon_32x32.png
sips -z 64 64   ./icon/icon.png --out icon.iconset/icon_32x32@2x.png
sips -z 128 128 ./icon/icon.png --out icon.iconset/icon_128x128.png
sips -z 256 256 ./icon/icon.png --out icon.iconset/icon_128x128@2x.png
sips -z 256 256 ./icon/icon.png --out icon.iconset/icon_256x256.png
sips -z 512 512 ./icon/icon.png --out icon.iconset/icon_256x256@2x.png
sips -z 512 512 ./icon/icon.png --out icon.iconset/icon_512x512.png
sips -z 1024 1024 ./icon/icon.png --out icon.iconset/icon_512x512@2x.png

iconutil -c icns icon.iconset

rm -R icon.iconset
mv icon.icns ./icon/icon.icns

# Make the small icon
sips -z 32 32 ./icon/icon-bw.png --out ./icon/icon_32x32.png

# Make the app
pyinstaller hovershot.spec

# Sign the app
codesign --deep --force --verbose --sign "HoverShot_Dev_ID" dist/HoverShot.app
codesign -dv --verbose=4 dist/HoverShot.app

mv dist/HoverShot.app .

rm -rf dist build