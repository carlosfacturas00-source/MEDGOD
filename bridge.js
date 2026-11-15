/* Med God iOS: puente que recrea window.estudio (lo que en escritorio hacía preload.js + main.js) usando el contenedor nativo. */
(function () {
  "use strict";
  if (window.estudio || !(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge)) return;
  const post = (op, ...a) => window.webkit.messageHandlers.bridge.postMessage({ op, a: a.map(x => x === undefined ? null : x) });
  const D = window.__MG_DATA || {};
  const LS = {};
  window.__mgEmit = (ch, p) => { (LS[ch] || []).forEach(f => { try { f(p) } catch (e) { } }) };
  const on = (ch, f) => { (LS[ch] = LS[ch] || []).push(f) };
  const em = e => e && e.userMsg ? (e.message || e.userMsg) : (e && e.message || String(e));

  /* ---------- archivos: se pasan en trozos (base64) al contenedor nativo ---------- */
  const b64 = ab => { const u = new Uint8Array(ab); let s = ""; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s) };
  async function sendFile(rel, blob) {
    const CH = 3145728, n = blob.size; let o = 0, first = true;
    do { const end = Math.min(o + CH, n); const ab = await blob.slice(o, end).arrayBuffer(); await post("lib.chunk", rel, b64(ab), first, end >= n); first = false; o = end } while (o < n);
    return true;
  }
  let fid = 0; const files = new Map();

  /* ---------- <webview> (Electron) → WKWebView nativo colocado encima del panel ---------- */
  const WV = new Map(); let wvn = 0;
  const mk = document.createElement.bind(document);
  function makeWebview() {
    const el = mk("div"), id = "wv" + (++wvn);
    let src = "", url = "", created = false, shown = false, last = "", gone = 0, dead = false, frame = 0;
    const ev = (t, d) => { const e = new Event(t); if (d) { if (d.url !== undefined) e.url = d.url; if (d.message !== undefined) e.message = d.message } el.dispatchEvent(e) };
    WV.set(id, { ev, setUrl: u => { url = u } });
    Object.defineProperty(el, "src", { get: () => src, set: v => { src = String(v || ""); url = src; if (created) post("wv.load", id, src) } });
    el.getURL = () => url || src;
    el.goBack = () => post("wv.back", id); el.goForward = () => post("wv.forward", id); el.reload = () => post("wv.reload", id);
    el.executeJavaScript = code => post("wv.exec", id, String(code));
    const loop = () => {
      if (dead) return;
      if (!el.isConnected) {
        if (++gone > 120) { dead = true; WV.delete(id); if (created) post("wv.destroy", id); return }
        if (created && shown) { shown = false; last = ""; post("wv.frame", id, 0, 0, 0, 0, false) }
        return requestAnimationFrame(loop);
      }
      gone = 0;
      const r = el.getBoundingClientRect();
      let vis = r.width > 4 && r.height > 4 && src !== "";
      if (vis && ++frame % 6 === 0) { const t = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(r.height / 2, 60)); vis = t === el || el.contains(t) } /* tapado por un menú/ventana → se oculta */
      else if (vis && !shown) vis = true;
      if (vis && !created) { created = true; post("wv.create", id, src) }
      if (created) {
        const key = Math.round(r.left) + "," + Math.round(r.top) + "," + Math.round(r.width) + "," + Math.round(r.height) + "," + vis;
        if (key !== last && (frame % 6 !== 0 || vis || shown)) { last = key; shown = vis; post("wv.frame", id, r.left, r.top, r.width, r.height, vis) }
      }
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
    return el;
  }
  document.createElement = function (tag, o) { return String(tag).toLowerCase() === "webview" ? makeWebview() : mk(tag, o) };
  on("wv", p => { const w = WV.get(p.id); if (!w) return; if (p.url) w.setUrl(p.url); w.ev(p.type, p) });

  /* ---------- sincronización de notas (misma lógica que la versión de escritorio) ---------- */
  const SYNCK = ["notes", "ndel", "exams", "hl", "pages", "videos", "pins", "ord", "nfolders", "pfolders", "icons", "secord", "whl"];
  const pj = (s, d) => { try { return s ? JSON.parse(s) : d } catch (_) { return d } };
  const sameN = (a, b) => JSON.stringify({ ...a, mt: 0 }) === JSON.stringify({ ...b, mt: 0 });
  const merge = (base, over) => { const o = { ...base }; for (const k in over) { if (k.endsWith("_t")) continue; if ((+over[k + "_t"] || 0) >= (+base[k + "_t"] || 0)) { o[k] = over[k]; o[k + "_t"] = over[k + "_t"] } } return o };
  async function devId() { let c = await post("cfg.get", "devId"); if (c) return c; const id = "iphone-" + Math.random().toString(36).slice(2, 6); await post("cfg.set", "devId", id); return id }
  function mergeTwo(L, R, apply, last, now, st) {
    const ln = pj(L.k.notes, {}), rn = pj(R.k.notes, {}), lT = +L.t.notes || 0, rT = +R.t.notes || 0;
    const del = { ...pj(R.k.ndel, {}) }, ld = pj(L.k.ndel, {}); for (const id in ld) del[id] = Math.max(del[id] || 0, ld[id]);
    const res = {}, copies = {};
    for (const id of new Set([...Object.keys(ln), ...Object.keys(rn)])) {
      const a = ln[id], b = rn[id]; let w;
      if (a && !b) w = a; else if (b && !a) w = b;
      else if (sameN(a, b)) w = a;
      else {
        const ma = a.mt || lT, mb = b.mt || rT; w = mb > ma ? b : a;
        const l = w === a ? b : a, dup = Object.values(ln).concat(Object.values(rn)).some(x => x.title === "⚠ Copia: " + l.title && x.body === l.body);
        if (apply && a.mt > last && b.mt > last && !dup) copies["n" + now + "c" + (++st.nc)] = { ...l, title: "⚠ Copia: " + l.title, mt: now, split: false };
      }
      if (del[id] && del[id] >= (w.mt || (w === a ? lT : rT))) continue;
      res[id] = w;
    }
    Object.assign(res, copies);
    for (const id in del) if (res[id] || now - del[id] > 90 * 864e5) delete del[id];
    const k = { notes: JSON.stringify(res), ndel: JSON.stringify(del) }, t = {};
    t.notes = k.notes === L.k.notes ? lT : k.notes === R.k.notes ? rT : now; t.ndel = k.ndel === L.k.ndel ? (+L.t.ndel || 0) : k.ndel === R.k.ndel ? (+R.t.ndel || 0) : now;
    for (const key of SYNCK) {
      if (key === "notes" || key === "ndel") continue;
      const lv = L.k[key], rv = R.k[key], lt = +L.t[key] || 0, rt = +R.t[key] || 0;
      if (lv === undefined && rv === undefined) continue;
      if (rv === undefined || (lv !== undefined && lt >= rt)) { k[key] = lv; t[key] = lt } else { k[key] = rv; t[key] = rt }
    }
    return { k, t };
  }
  async function syncNotes(apply) {
    const names = await post("folder.list", "notes", "");
    if (!names) throw { userMsg: "No encuentro la carpeta de sincronización. Elígela otra vez (botón ⋯ → Carpeta de sincronización de notas). Si es de Google Drive/Dropbox, ábrela una vez en la app Archivos para que se descargue." };
    await post("data.flush");
    const mineName = "MedGod-notas-" + await devId() + ".json", now = Date.now(), last = +(await post("cfg.get", "lastSync")) || 0;
    let M = { k: {}, t: {} }; for (const k of SYNCK) if (D[k] !== undefined) { M.k[k] = D[k]; M.t[k] = +D[k + "_t"] || 0 }
    const L0 = pj(M.k.notes, {}); let seen = 0; const bad = [], st = { nc: 0 };
    if (apply) {
      const others = names.filter(n => /^MedGod-notas.*\.json$/i.test(n) && n !== mineName);
      for (const n of others) {
        let R = null; try { R = JSON.parse(await post("folder.read", "notes", n)) } catch (_) { }
        if (!R || !R.k) { bad.push(n); continue }
        seen++; M = mergeTwo(M, R, true, last, now, st);
      }
      if (others.length && !seen) throw { userMsg: "No pude leer los archivos del drive (quizá aún se están descargando). Espera unos segundos y reintenta." };
      const upd = {};
      for (const k of SYNCK) if (M.k[k] !== undefined && M.k[k] !== D[k]) { const nt = String(Math.max(now, (+D[k + "_t"] || 0) + 1)); D[k] = M.k[k]; D[k + "_t"] = nt; upd[k] = D[k]; upd[k + "_t"] = nt }
      if (Object.keys(upd).length) await post("data.write", upd);
      await post("data.flush"); await post("cfg.set", "lastSync", now);
    }
    const body = JSON.stringify({ t: M.t, k: M.k });
    let prev = null; try { prev = JSON.parse(await post("folder.read", "notes", mineName)) } catch (_) { }
    if (!prev || JSON.stringify({ t: prev.t, k: prev.k }) !== body) await post("folder.write", "notes", mineName, JSON.stringify({ v: 2, by: "iPhone", at: now, t: M.t, k: M.k }));
    const F = pj(M.k.notes, {}); let added = 0, upd2 = 0, removed = 0;
    for (const id in F) { if (!L0[id]) added++; else if (!sameN(F[id], L0[id])) upd2++ } for (const id in L0) if (!F[id]) removed++;
    const tip = apply && !seen ? " · Aún no veo notas de otros equipos (¿ya sincronizó el drive?)" : "";
    return { msg: apply ? "✔ Notas sincronizadas: " + added + " nueva(s), " + upd2 + " actualizada(s), " + removed + " eliminada(s)" + (st.nc ? " · ⚠ " + st.nc + " conflicto(s): guardé copia(s) con «⚠ Copia»" : "") + (bad.length ? " · No pude leer " + bad.length + " archivo(s); reintenta" : "") + tip : "ok" };
  }
  const okRel = s => typeof s === "string" && s && !/^([a-z]:|[\\/])|(^|[\\/])\.\.([\\/]|$)/i.test(s);
  const noteSrcs = () => [...new Set(Object.values(pj(D.notes, {})).map(n => n && n.src).filter(okRel))];
  async function docsSync(push, pull) {
    let up = 0, down = 0; if (!(await post("folder.get", "notes"))) return { up, down };
    for (const s of noteSrcs()) {
      try {
        const r = await post("folder.syncfile", "notes", "MedGod-docs/" + s, s, push, pull);
        if (r === "up") up++; else if (r === "down") down++;
      } catch (_) { }
    }
    return { up, down };
  }
  const needCloud = async () => { if (!(await post("folder.get", "cloud"))) throw new Error("Primero elige la carpeta de la nube") };

  const noAcct = async () => { throw new Error("En iPhone no hace falta conectar cuentas: usa «Subir archivos» y elige el archivo desde la app Archivos (ahí aparecen Google Drive, Dropbox, OneDrive e iCloud).") };

  window.estudio = {
    readDataSync: () => D,
    writeData: o => { try { Object.assign(D, o) } catch (_) { } post("data.write", o) },
    webFetch: u => post("web.fetch", u),
    listLib: () => post("lib.list"),
    addFiles: async list => { for (const { rel, src } of list) { const f = files.get(src); if (f) await sendFile(rel, f) } files.clear(); return true },
    delFile: rel => post("lib.del", rel),
    clearLib: () => post("lib.clear"),
    openLib: () => post("lib.open"),
    writeLib: async (rel, buf) => { await sendFile(rel, new Blob([Array.isArray(buf) ? new Uint8Array(buf) : buf])); return true },
    print: h => post("print.html", h),
    printPdf: (h, n) => post("print.pdf", h, n),
    warmPrint: async () => true,
    pathOf: f => { const id = "mgfile:" + (++fid); files.set(id, f); return id },
    aiCall: o => post("ai.call", o),
    usbGet: async () => [], usbAdd: async () => [], usbDel: async () => [],
    usbSync: async () => "⚠ USB no existe en iPhone: usa «Subir archivos» y elige desde la app Archivos.",
    syncGet: () => post("folder.get", "notes"),
    syncChoose: async () => { const r = await post("folder.pick", "notes"); if (r) await post("cfg.set", "lastSync", 0); return r || "" },
    syncRun: async () => { try { const r = await syncNotes(true), dd = await docsSync(true, true); return r.msg + (dd.down ? " · " + dd.down + " documento(s) descargado(s)" : "") + (dd.up ? " · " + dd.up + " documento(s) subido(s)" : "") } catch (e) { return "⚠ " + em(e) } },
    syncPush: async now => { try { if (!(await post("folder.get", "notes"))) return now ? "⚠ Primero elige la carpeta de sincronización (botón ⋯)" : ""; await syncNotes(false); const dd = await docsSync(true, false); return now ? "✔ Notas subidas al drive" + (dd.up ? " + " + dd.up + " documento(s)" : "") + ". Abre la app del drive para que termine de subir." : "" } catch (e) { return now ? "⚠ " + em(e) : "" } },
    onSync: cb => on("sync", cb),
    cloudGet: () => post("folder.get", "cloud"),
    cloudChoose: async () => (await post("folder.pick", "cloud")) || "",
    cloudUp: async () => {
      await needCloud(); await post("data.flush");
      let rem = {}; try { rem = JSON.parse(await post("folder.read", "cloud", "data.json") || "{}") } catch (_) { }
      await post("folder.write", "cloud", "data.json", JSON.stringify(merge(rem, D)));
      const n = await post("folder.copytree", "cloud", "library", true);
      return "✔ Subido: tus datos y " + n + " archivo(s) nuevo(s)";
    },
    cloudDown: async () => {
      await needCloud(); await post("data.flush");
      let rem = {}; try { rem = JSON.parse(await post("folder.read", "cloud", "data.json") || "{}") } catch (_) { }
      const m = merge(D, rem), upd = {}; for (const k in m) if (m[k] !== D[k]) upd[k] = m[k];
      Object.assign(D, upd); await post("data.write", upd); await post("data.flush");
      const n = await post("folder.copytree", "cloud", "library", false);
      return "✔ Descargado: datos al día y " + n + " archivo(s) nuevo(s)";
    },
    acctState: async () => ({}), acctSetup: noAcct, acctConnect: noAcct, acctDisconnect: async () => ({}),
    acctList: noAcct, acctImport: noAcct, acctCancel: async () => true,
    onProgress: cb => on("progress", cb),
    onFocus: cb => on("focus", cb)
  };

  /* ---------- botón ⋯ (sustituye al menú «Archivo» de escritorio) ---------- */
  document.addEventListener("DOMContentLoaded", () => {
    const b = mk("button");
    b.textContent = "⋯"; b.setAttribute("aria-label", "Menú de sincronización");
    b.style.cssText = "position:fixed;left:6px;bottom:6px;z-index:2147483000;width:34px;height:34px;border-radius:17px;border:1px solid #ffffff33;background:#000000b0;color:#fff;font-size:20px;line-height:1;opacity:.5;padding:0";
    b.onclick = async () => {
      const i = await post("menu", ["🔄 Sincronizar notas", "⬆ Subir nota ahora", "📁 Carpeta de sincronización de notas…", "↻ Recargar la app"]);
      if (i === 0) window.__mgEmit("sync", "run"); else if (i === 1) window.__mgEmit("sync", "push"); else if (i === 2) window.__mgEmit("sync", "choose"); else if (i === 3) location.reload();
    };
    document.body.appendChild(b);
  });
})();
