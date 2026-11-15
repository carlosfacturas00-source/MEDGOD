import Foundation
import UIKit
import WebKit
import UniformTypeIdentifiers

// MARK: - Rutas (Documentos/Med God: visible en la app Archivos → "En mi iPhone" → Med God)
enum Paths {
    static let fm = FileManager.default
    static let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let dataDir = docs.appendingPathComponent("Med God", isDirectory: true)
    static let lib = dataDir.appendingPathComponent("library", isDirectory: true)
    static let dataFile = dataDir.appendingPathComponent("data.json")
    static let bakFile = dataDir.appendingPathComponent("data.bak.json")
    static var web: URL { Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true) }

    static func setup() { try? fm.createDirectory(at: lib, withIntermediateDirectories: true) }

    /// Convierte "a/b/c.pdf" en una URL dentro de `root`, rechazando rutas peligrosas.
    static func url(in root: URL, _ rel: String) -> URL? {
        let parts = rel.split(separator: "/").map(String.init)
        if parts.isEmpty || parts.contains("..") || parts.contains(".") { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    static func walk(_ root: URL) -> [(rel: String, size: Int)] {
        var out: [(rel: String, size: Int)] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return out }
        let base = root.resolvingSymlinksInPath().path
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            let name = u.lastPathComponent
            if name.hasSuffix(".part") || name == ".DS_Store" { continue }
            var rel = u.resolvingSymlinksInPath().path
            if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append((rel, v.fileSize ?? 0))
        }
        return out
    }
}

// MARK: - Datos de la app (equivale a data.json de la versión de escritorio)
final class DataStore {
    static let shared = DataStore()
    private(set) var cache: [String: Any] = [:]
    private var pending: DispatchWorkItem?
    private var loaded = false

    func load() {
        func read(_ u: URL) -> [String: Any]? {
            guard let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }
        if let o = read(Paths.dataFile) {
            cache = o
            try? Paths.fm.removeItem(at: Paths.bakFile)
            try? Paths.fm.copyItem(at: Paths.dataFile, to: Paths.bakFile)
        } else if let o = read(Paths.bakFile) {
            cache = o
        }
        loaded = true
    }

    var jsonText: String {
        guard let d = try? JSONSerialization.data(withJSONObject: cache), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    func merge(_ o: [String: Any]) {
        guard loaded else { return }
        for (k, v) in o { cache[k] = v }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.writeNow() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func flush() { pending?.cancel(); writeNow() }

    private func writeNow() {
        pending = nil
        guard loaded, let d = try? JSONSerialization.data(withJSONObject: cache) else { return }
        try? d.write(to: Paths.dataFile, options: .atomic)
    }
}

enum Cfg {
    static func get(_ k: String) -> Any? { UserDefaults.standard.object(forKey: "mg.cfg." + k) }
    static func set(_ k: String, _ v: Any?) { UserDefaults.standard.set(v, forKey: "mg.cfg." + k) }
}

// MARK: - Carpetas externas (Archivos: iCloud Drive, Google Drive, Dropbox, OneDrive…) con permiso persistente
final class Folders {
    static let shared = Folders()
    private let fm = FileManager.default
    private var active: [String: URL] = [:]
    private let lock = NSLock()

    func store(_ key: String, _ url: URL) -> Bool {
        _ = url.startAccessingSecurityScopedResource()
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        UserDefaults.standard.set(bm, forKey: "mg.bm." + key)
        lock.lock(); active[key] = url; lock.unlock()
        return true
    }

    func resolve(_ key: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let u = active[key] { return u }
        guard let bm = UserDefaults.standard.data(forKey: "mg.bm." + key) else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = u.startAccessingSecurityScopedResource()
        active[key] = u
        return u
    }

    func path(_ key: String) -> String { resolve(key)?.path ?? "" }

    func list(_ key: String, _ sub: String) -> [String]? {
        guard let root = resolve(key) else { return nil }
        let dir = sub.isEmpty ? root : root.appendingPathComponent(sub, isDirectory: true)
        var res: [String]? = nil
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &err) { u in
            res = try? self.fm.contentsOfDirectory(atPath: u.path)
        }
        return res
    }

    func readText(_ key: String, _ rel: String) -> String? {
        guard let root = resolve(key), let u = Paths.url(in: root, rel) else { return nil }
        var out: String? = nil
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: u, options: [], error: &err) { cu in
            if let d = try? Data(contentsOf: cu) { out = String(data: d, encoding: .utf8) }
        }
        return out
    }

    func writeText(_ key: String, _ rel: String, _ text: String) -> Bool {
        guard let root = resolve(key), let u = Paths.url(in: root, rel) else { return false }
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: u, options: .forReplacing, error: &err) { cu in
            ok = (try? Data(text.utf8).write(to: cu, options: .atomic)) != nil
        }
        return ok
    }

    func copy(_ src: URL, _ dst: URL) -> Bool {
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], writingItemAt: dst, options: .forReplacing, error: &err) { r, w in
            try? self.fm.removeItem(at: w)
            ok = (try? self.fm.copyItem(at: r, to: w)) != nil
        }
        return ok
    }

    private func attr(_ u: URL) -> (size: Int, date: Date) {
        let a = try? fm.attributesOfItem(atPath: u.path)
        return ((a?[.size] as? NSNumber)?.intValue ?? 0, (a?[.modificationDate] as? Date) ?? .distantPast)
    }

    /// Documento ligado a una nota: "up" si se subió, "down" si se bajó, "" si no se hizo nada.
    func syncFile(_ key: String, _ rel: String, _ libRel: String, push: Bool, pull: Bool) -> String {
        guard let root = resolve(key), let R = Paths.url(in: root, rel), let L = Paths.url(in: Paths.lib, libRel) else { return "" }
        let le = fm.fileExists(atPath: L.path), re = fm.fileExists(atPath: R.path)
        if push && le && (!re || (attr(R).size != attr(L).size && attr(L).date > attr(R).date)) { return copy(L, R) ? "up" : "" }
        if pull && !le && re { return copy(R, L) ? "down" : "" }
        return ""
    }

    func copyTree(_ key: String, _ sub: String, up: Bool, progress: @escaping (String) -> Void) -> Int {
        guard let root = resolve(key) else { return 0 }
        let remote = root.appendingPathComponent(sub, isDirectory: true)
        let src = up ? Paths.lib : remote, dst = up ? remote : Paths.lib
        let list = Paths.walk(src)
        var n = 0
        for (i, f) in list.enumerated() {
            guard let s = Paths.url(in: src, f.rel), let t = Paths.url(in: dst, f.rel) else { continue }
            let tsize = (try? fm.attributesOfItem(atPath: t.path))?[.size] as? NSNumber
            if tsize?.intValue != f.size, copy(s, t) { n += 1 }
            if (i + 1) % 3 == 0 { progress("Procesando \(i + 1) de \(list.count)…") }
        }
        return n
    }
}

final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    var key = ""
    var done: ((String) -> Void)?
    func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let u = urls.first, Folders.shared.store(key, u) else { done?(""); return }
        done?(u.path)
    }
    func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { done?("") }
}

// MARK: - Protocolo app://x/ (equivale al de Electron: index.html, /__npm/ y /__lib/)
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let path = url.path
        var file: URL? = nil
        if path == "/" || path == "/index.html" { file = Paths.web.appendingPathComponent("index.html") }
        else if path.hasPrefix("/__lib/") { file = Paths.url(in: Paths.lib, String(path.dropFirst(7))) }
        else if path.hasPrefix("/__npm/") { file = Paths.url(in: Paths.web.appendingPathComponent("__npm"), String(path.dropFirst(7))) }

        guard let f = file, let data = try? Data(contentsOf: f, options: .mappedIfSafe) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(r); task.didReceive(Data()); task.didFinish(); return
        }
        let ext = f.pathExtension.lowercased()
        var mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        if ext == "js" { mime = "text/javascript" }
        if ext == "html" { mime = "text/html;charset=utf-8" }
        var status = 200
        var body = data
        var headers = ["Content-Type": mime, "Access-Control-Allow-Origin": "*", "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if let r = task.request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let spec = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            var s = Int(spec.first ?? "")
            var e = spec.count > 1 ? Int(spec[1]) : nil
            if s == nil, let suffix = e { s = max(0, data.count - suffix); e = data.count - 1 }
            let start = s ?? 0, end = min(e ?? data.count - 1, data.count - 1)
            if start <= end && start < data.count {
                body = data.subdata(in: start..<(end + 1))
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
            }
        }
        headers["Content-Length"] = String(body.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp); task.didReceive(body); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
