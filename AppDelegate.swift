import UIKit
import WebKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = MainViewController()
        window?.makeKeyAndVisible()
        return true
    }
}

final class MainViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    private var web: WKWebView!
    private let bridge = Bridge()
    private var bridgeJS = ""
    private var downloadDest: [ObjectIdentifier: URL] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1)
        Paths.setup()
        DataStore.shared.load()
        bridgeJS = (try? String(contentsOf: Paths.web.appendingPathComponent("bridge.js"), encoding: .utf8)) ?? ""

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: "app")
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "bridge")
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.keyboardDismissMode = .interactive
        web.isOpaque = false
        web.backgroundColor = view.backgroundColor
        if #available(iOS 16.4, *) { web.isInspectable = true }
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: g.topAnchor), web.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: g.leadingAnchor), web.trailingAnchor.constraint(equalTo: g.trailingAnchor)
        ])
        bridge.web = web
        bridge.vc = self
        installScripts()
        web.load(URLRequest(url: URL(string: "app://x/")!))

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(saveNow), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(saveNow), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func saveNow() { DataStore.shared.flush() }
    @objc private func becameActive() { bridge.emit("focus", true) }

    /// Los datos se inyectan antes de que arranque la página (equivale a readDataSync de Electron).
    private func installScripts() {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: "window.__MG_DATA=" + DataStore.shared.jsonText + ";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    // MARK: navegación
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        let sch = url.scheme ?? ""
        if sch == "app" { installScripts(); decisionHandler(.allow); return }
        if ["about", "blob", "data"].contains(sch) { decisionHandler(.allow); return }
        if ["http", "https", "mailto", "tel"].contains(sch) { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        installScripts()
        w.reload()
    }
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url, ["http", "https"].contains(u.scheme ?? "") { UIApplication.shared.open(u) }
        return nil
    }

    // MARK: descargas (⬇ Exportar, Descargar PDF…): se guardan y se abre la hoja de compartir (Guardar en Archivos)
    func webView(_ w: WKWebView, navigationAction a: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse r: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedFilename.isEmpty ? "archivo" : suggestedFilename)
        downloadDest[ObjectIdentifier(d)] = dest
        completionHandler(dest)
    }
    func downloadDidFinish(_ d: WKDownload) {
        if let u = downloadDest.removeValue(forKey: ObjectIdentifier(d)) { Share.present(u, from: self) }
    }
    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) { downloadDest.removeValue(forKey: ObjectIdentifier(d)) }

    // MARK: alert / confirm / prompt (WKWebView no los muestra solo)
    private func top() -> UIViewController { presentedViewController ?? self }
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        top().present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        top().present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        top().present(a, animated: true)
    }
}
