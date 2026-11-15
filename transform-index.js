// Prepara Web/index.html a partir de app-src/index.html (la misma interfaz de escritorio)
const fs = require("fs");
let h = fs.readFileSync(__dirname + "/app-src/index.html", "utf8");
const CDN = [
  ["https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js", "/__npm/pdfjs-dist/build/pdf.min.js"],
  ["https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js", "/__npm/pdfjs-dist/build/pdf.worker.min.js"],
  ["https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js", "/__npm/jszip/dist/jszip.min.js"],
  ["https://cdnjs.cloudflare.com/ajax/libs/epub.js/0.3.93/epub.min.js", "/__npm/epubjs/dist/epub.min.js"],
  ["https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js", "/__npm/jspdf/dist/jspdf.umd.min.js"],
  ["https://cdnjs.cloudflare.com/ajax/libs/mammoth/1.6.0/mammoth.browser.min.js", "/__npm/mammoth/mammoth.browser.min.js"],
  ["https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js", "/__npm/xlsx/dist/xlsx.full.min.js"]
];
let n = 0;
for (const [a, b] of CDN) { const c = h.split(a).length - 1; n += c; h = h.split(a).join(b); }
// Evita el zoom automático de iOS al tocar un campo y el zoom por pellizco (en escritorio se limitaba igual)
const vp = 'viewport-fit=cover"';
if (!h.includes(vp)) throw new Error("No encontré la etiqueta viewport");
h = h.replace(vp, 'viewport-fit=cover, maximum-scale=1, user-scalable=no"');
fs.mkdirSync(__dirname + "/Web", { recursive: true });
fs.writeFileSync(__dirname + "/Web/index.html", h);
console.log("index.html listo (" + n + " referencias a librerías apuntan ahora a archivos locales)");
