import UIKit
import WebKit
import UniformTypeIdentifiers

/// Una página HTML oculta que sirve para imprimir o generar PDF.
final class HTMLJob: NSObject, WKNavigationDelegate {
    let web: WKWebView
    var onLoad: ((WKWebView) -> Void)?
    init(html: String, host: UIView) {
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792), configuration: WKWebViewConfiguration())
        super.init()
        web.alpha = 0.01
        web.navigationDelegate = self
        host.insertSubview(web, at: 0)
        web.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { onLoad?(w) }
}

enum Share {
    static func present(_ url: URL, from vc: UIViewController?) {
        guard let vc = vc else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let p = av.popoverPresentationController {
            p.sourceView = vc.view
            p.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
            p.permittedArrowDirections = []
        }
        (vc.presentedViewController ?? vc).present(av, animated: true)
    }
}

/// Equivale a preload.js + los ipcMain de la versión de escritorio.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var web: WKWebView?
    weak var vc: UIViewController?
    private var children: [String: ChildWeb] = [:]
    private var jobs = Set<HTMLJob>()
    private var picker: FolderPicker?
    private let bg = DispatchQueue(label: "medgod.bg", qos: .userInitiated, attributes: .concurrent)
    static let aiHosts: Set<String> = ["api.anthropic.com", "api.deepseek.com", "generativelanguage.googleapis.com",
                                       "api.openai.com", "api.perplexity.ai", "api.x.ai"]

    // Swift → JS
    func emit(_ channel: String, _ payload: Any) {
        guard JSONSerialization.isValidJSONObject([payload]),
              let d = try? JSONSerialization.data(withJSONObject: [payload]),
              let s = String(data: d, encoding: .utf8) else { return }
        let js = "window.__mgEmit&&window.__mgEmit(\"\(channel)\"," + s + "[0])"
        DispatchQueue.main.async { self.web?.evaluateJavaScript(js, completionHandler: nil) }
    }
    func emitWV(_ id: String, _ type: String, url: String? = nil, message: String? = nil) {
        var p: [String: Any] = ["id": id, "type": type]
        if let u = url { p["url"] = u }
        if let m = message { p["message"] = m }
        emit("wv", p)
    }

    // JS → Swift
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { replyHandler(nil, "mensaje inválido"); return }
        let a = body["a"] as? [Any] ?? []
        var replied = false
        let done: (Any?) -> Void = { v in
            DispatchQueue.main.async {
                if replied { return }
                replied = true
                replyHandler(v is NSNull ? nil : v, nil)
            }
        }
        handle(op, a, done)
    }

    private func handle(_ op: String, _ a: [Any], _ done: @escaping (Any?) -> Void) {
        func str(_ i: Int) -> String { (i < a.count ? a[i] as? String : nil) ?? "" }
        func num(_ i: Int) -> Double { (i < a.count ? (a[i] as? NSNumber)?.doubleValue : nil) ?? 0 }
        func flag(_ i: Int) -> Bool { (i < a.count ? (a[i] as? NSNumber)?.boolValue : nil) ?? false }

        switch op {
        // ---- datos ----
        case "data.write":
            if let o = a.first as? [String: Any] { DataStore.shared.merge(o) }
            done(true)
        case "data.flush":
            DataStore.shared.flush(); done(true)
        case "cfg.get":
            done(Cfg.get(str(0)))
        case "cfg.set":
            Cfg.set(str(0), a.count > 1 && !(a[1] is NSNull) ? a[1] : nil); done(true)

        // ---- biblioteca ----
        case "lib.list":
            bg.async { done(Paths.walk(Paths.lib).map { ["path": $0.rel, "size": $0.size] }) }
        case "lib.chunk":
            let rel = str(0), b64 = str(1), first = flag(2), last = flag(3)
            bg.async {
                guard let dst = Paths.url(in: Paths.lib, rel), let data = Data(base64Encoded: b64) else { done(false); return }
                let part = dst.appendingPathExtension("part")
                try? Paths.fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if first { try? Paths.fm.removeItem(at: part); Paths.fm.createFile(atPath: part.path, contents: nil) }
                guard let h = try? FileHandle(forWritingTo: part) else { done(false); return }
                h.seekToEndOfFile(); h.write(data); h.closeFile()
                if last { try? Paths.fm.removeItem(at: dst); try? Paths.fm.moveItem(at: part, to: dst) }
                done(true)
            }
        case "lib.del":
            if let u = Paths.url(in: Paths.lib, str(0)) { try? Paths.fm.removeItem(at: u) }
            done(true)
        case "lib.clear":
            try? Paths.fm.removeItem(at: Paths.lib); Paths.setup(); done(true)
        case "lib.open":
            if let u = URL(string: "shareddocuments://" + Paths.dataDir.path) { UIApplication.shared.open(u) }
            done(true)

        // ---- red ----
        case "ai.call": aiCall(a.first as? [String: Any] ?? [:], done)
        case "web.fetch": webFetch(str(0), done)

        // ---- imprimir / PDF ----
        case "print.html": printHTML(str(0), done)
        case "print.pdf": pdfHTML(str(0), name: str(1), done)

        // ---- carpetas externas (Archivos) ----
        case "folder.get": done(Folders.shared.path(str(0)))
        case "folder.pick": pickFolder(str(0), done)
        case "folder.list":
            let k = str(0), sub = str(1)
            bg.async { done(Folders.shared.list(k, sub)) }
        case "folder.read":
            let k = str(0), rel = str(1)
            bg.async { done(Folders.shared.readText(k, rel)) }
        case "folder.write":
            let k = str(0), rel = str(1), txt = str(2)
            bg.async { done(Folders.shared.writeText(k, rel, txt)) }
        case "folder.syncfile":
            let k = str(0), rel = str(1), lrel = str(2), push = flag(3), pull = flag(4)
            bg.async { done(Folders.shared.syncFile(k, rel, lrel, push: push, pull: pull)) }
        case "folder.copytree":
            let k = str(0), sub = str(1), up = flag(2)
            bg.async { done(Folders.shared.copyTree(k, sub, up: up) { [weak self] t in self?.emit("progress", t) }) }

        // ---- menú nativo ----
        case "menu": showMenu(a.first as? [String] ?? [], done)

        // ---- paneles de página web nativos ----
        case "wv.create":
            let id = str(0)
            children[id]?.destroy()
            let c = ChildWeb(id: id, host: self)
            children[id] = c
            web?.addSubview(c.web)
            c.load(str(1))
            done(true)
        case "wv.frame":
            if let c = children[str(0)] {
                c.web.frame = CGRect(x: num(1), y: num(2), width: num(3), height: num(4))
                c.web.isHidden = !flag(5)
            }
            done(true)
        case "wv.load": children[str(0)]?.load(str(1)); done(true)
        case "wv.back": children[str(0)]?.web.goBack(); done(true)
        case "wv.forward": children[str(0)]?.web.goForward(); done(true)
        case "wv.reload": children[str(0)]?.web.reload(); done(true)
        case "wv.exec":
            guard let c = children[str(0)] else { done(nil); return }
            c.web.evaluateJavaScript(str(1)) { r, _ in done(r) }
        case "wv.destroy":
            children[str(0)]?.destroy(); children[str(0)] = nil; done(true)

        case "log": print("[MedGod JS]", str(0)); done(true)
        default: done(nil)
        }
    }

    // MARK: IA
    private func aiCall(_ o: [String: Any], _ done: @escaping (Any?) -> Void) {
        guard let s = o["url"] as? String, let url = URL(string: s), url.scheme == "https",
              let host = url.host, Bridge.aiHosts.contains(host) else {
            done(["ok": false, "status": 0, "text": "Destino no permitido"]); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        (o["headers"] as? [String: Any])?.forEach { if let v = $0.value as? String { req.setValue(v, forHTTPHeaderField: $0.key) } }
        if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let b = o["body"] as? String { req.httpBody = b.data(using: .utf8) }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { done(["ok": false, "status": 0, "text": err.localizedDescription]); return }
            let st = (resp as? HTTPURLResponse)?.statusCode ?? 0
            done(["ok": (200..<300).contains(st), "status": st, "text": String(data: data ?? Data(), encoding: .utf8) ?? ""])
        }.resume()
    }

    // MARK: páginas web (importar)
    private func decode(_ d: Data, _ cs: String?) -> String {
        if let cs = cs {
            let enc = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if enc != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(enc)
                if let s = String(data: d, encoding: String.Encoding(rawValue: ns)) { return s }
            }
        }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }
    private func webFetch(_ s: String, _ done: @escaping (Any?) -> Void) {
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { done(["error": "Solo enlaces http o https"]); return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("es,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let e = err as NSError? { done(["error": e.code == NSURLErrorTimedOut ? "Tardó demasiado en responder" : e.localizedDescription]); return }
            guard let r = resp as? HTTPURLResponse, let d = data else { done(["error": "Sin respuesta"]); return }
            if !(200..<300).contains(r.statusCode) { done(["error": "La página respondió \(r.statusCode)"]); return }
            let ct = r.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct.lowercased().contains("pdf") { done(["error": "Es un PDF: descárgalo y súbelo a la biblioteca."]); return }
            if d.count > 6_000_000 { done(["error": "La página es demasiado grande"]); return }
            var cs: String? = nil
            let rx = try? NSRegularExpression(pattern: "charset=[\"']?([\\w-]+)", options: .caseInsensitive)
            let head = String(decoding: d.prefix(4096), as: UTF8.self)
            for text in [ct, head] where cs == nil {
                if let m = rx?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let rg = Range(m.range(at: 1), in: text) { cs = String(text[rg]) }
            }
            done(["html": self.decode(d, cs), "url": r.url?.absoluteString ?? u.absoluteString])
        }.resume()
    }

    // MARK: imprimir
    private func printHTML(_ html: String, _ done: @escaping (Any?) -> Void) {
        guard let host = vc?.view else { done(false); return }
        let job = HTMLJob(html: html, host: host)
        jobs.insert(job)
        job.onLoad = { [weak self, weak job] web in
            let c = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = "Med God"
            c.printInfo = info
            c.printFormatter = web.viewPrintFormatter()
            c.present(animated: true) { _, completed, _ in
                if let j = job { j.web.removeFromSuperview(); self?.jobs.remove(j) }
                done(completed)
            }
        }
    }

    private func pdfHTML(_ html: String, name: String, _ done: @escaping (Any?) -> Void) {
        guard let host = vc?.view else { done(false); return }
        let job = HTMLJob(html: html, host: host)
        jobs.insert(job)
        job.onLoad = { [weak self, weak job] web in
            defer { if let j = job { j.web.removeFromSuperview(); self?.jobs.remove(j) } }
            let r = UIPrintPageRenderer()
            r.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
            let paper = CGRect(x: 0, y: 0, width: 612, height: 792)
            r.setValue(NSValue(cgRect: paper), forKey: "paperRect")
            r.setValue(NSValue(cgRect: paper.insetBy(dx: 36, dy: 36)), forKey: "printableRect")
            let pages = r.numberOfPages
            guard pages > 0 else { done(false); return }
            let data = NSMutableData()
            UIGraphicsBeginPDFContextToData(data, paper, nil)
            r.prepare(forDrawingPages: NSRange(location: 0, length: pages))
            let b = UIGraphicsGetPDFContextBounds()
            for i in 0..<pages { UIGraphicsBeginPDFPage(); r.drawPage(at: i, in: b) }
            UIGraphicsEndPDFContext()
            var fname = name.replacingOccurrences(of: "/", with: "-")
            if fname.isEmpty { fname = "nota.pdf" }
            if !fname.lowercased().hasSuffix(".pdf") { fname += ".pdf" }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(fname)
            do { try (data as Data).write(to: tmp, options: .atomic) } catch { done(false); return }
            Share.present(tmp, from: self?.vc)
            done(true)
        }
    }

    // MARK: carpetas / menú
    private func pickFolder(_ key: String, _ done: @escaping (Any?) -> Void) {
        let p = FolderPicker()
        p.key = key
        p.done = { [weak self] r in self?.picker = nil; done(r) }
        picker = p
        let dp = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        dp.delegate = p
        dp.allowsMultipleSelection = false
        vc?.present(dp, animated: true)
    }

    private func showMenu(_ items: [String], _ done: @escaping (Any?) -> Void) {
        guard let vc = vc else { done(-1); return }
        let sheet = UIAlertController(title: "Med God", message: nil, preferredStyle: .actionSheet)
        for (i, t) in items.enumerated() { sheet.addAction(UIAlertAction(title: t, style: .default) { _ in done(i) }) }
        sheet.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in done(-1) })
        if let p = sheet.popoverPresentationController {
            p.sourceView = vc.view
            p.sourceRect = CGRect(x: 30, y: vc.view.bounds.height - 60, width: 1, height: 1)
        }
        vc.present(sheet, animated: true)
    }
}
