#!/bin/bash
# Descarga las librerías (pdf.js, jszip, epub.js, jspdf, mammoth, xlsx) y deja Web/ listo para compilar.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf Web/__npm Web/index.html .npm-tmp
mkdir -p Web/__npm .npm-tmp
cp app-src/package.json .npm-tmp/package.json
( cd .npm-tmp && npm install --omit=dev --omit=optional --no-audit --no-fund --loglevel=error )
for f in pdfjs-dist/build/pdf.min.js pdfjs-dist/build/pdf.worker.min.js jszip/dist/jszip.min.js epubjs/dist/epub.min.js \
         jspdf/dist/jspdf.umd.min.js mammoth/mammoth.browser.min.js xlsx/dist/xlsx.full.min.js; do
  [ -f ".npm-tmp/node_modules/$f" ] || { echo "Falta $f en node_modules"; exit 1; }
  mkdir -p "Web/__npm/$(dirname "$f")"
  cp ".npm-tmp/node_modules/$f" "Web/__npm/$f"
done
node transform-index.js
rm -rf .npm-tmp
echo "Web/ listo."
