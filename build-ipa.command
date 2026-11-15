#!/bin/bash
# Compila MedGod.ipa (sin firmar) en tu Mac. SideStore / AltStore / Sideloadly lo firman al instalarlo.
cd "$(dirname "$0")"
set -e
command -v node >/dev/null || { echo "Falta Node.js: instálalo desde https://nodejs.org y vuelve a abrir este archivo."; exit 1; }
command -v xcodebuild >/dev/null || { echo "Falta Xcode: instálalo desde la App Store, ábrelo una vez y acepta la licencia."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Falta Homebrew (https://brew.sh). Instálalo y vuelve a abrir este archivo."; exit 1; }
  brew install xcodegen
fi
bash prepare-web.sh
xcodegen generate
rm -rf build Payload MedGod.ipa
xcodebuild -project MedGod.xcodeproj -scheme MedGod -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" clean build
mkdir Payload
cp -R build/Build/Products/Release-iphoneos/MedGod.app Payload/
zip -qr MedGod.ipa Payload
rm -rf Payload
echo ""; echo "Listo: $(pwd)/MedGod.ipa"
open .
