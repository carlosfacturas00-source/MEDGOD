import UIKit
import WebKit

/// Sustituto del <webview> de Electron: un WKWebView nativo colocado encima del panel de la página.
final class ChildWeb: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: String
    let web: WKWebView
    weak var host: Bridge?
    private var obs: NSKeyValueObservation?

    // Reenvía console.log("__MG__…") (lo usa la función de subrayar) y convierte la selección táctil en un "mouseup".
    private static let js = """
    (function(){
      try{['log','info','warn','debug'].forEach(function(n){var o=console[n];console[n]=function(){
        try{var m=arguments[0];if(typeof m==='string'&&m.indexOf('__MG__')===0)window.webkit.messageHandlers.mgconsole.postMessage(m)}catch(e){}
        return o.apply(console,arguments)}})}catch(e){}
      var t;document.addEventListener('selectionchange',function(){clearTimeout(t);t=setTimeout(function(){
        try{var s=getSelection();if(s&&!s.isCollapsed&&String(s).trim()&&s.rangeCount){var r=s.getRangeAt(0).getBoundingClientRect();
        document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,clientX:r.left+r.width/2,clientY:r.bottom}))}}catch(e){}},450)});
    })();
    """

    init(id: String, host: Bridge) {
        self.id = id
        self.host = host
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: ChildWeb.js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "mgconsole")
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.backgroundColor = .white
        web.isHidden = true
        obs = web.observe(\.url, options: [.new]) { [weak self] w, _ in
            guard let self = self, let u = w.url?.absoluteString else { return }
            self.host?.emitWV(self.id, "did-navigate-in-page", url: u)
        }
    }

    func load(_ s: String) {
        if s.isEmpty || s == "about:blank" { web.loadHTMLString("", baseURL: nil); return }
        guard let u = URL(string: s) else { return }
        var req = URLRequest(url: u)
        if (u.host ?? "").contains("youtube.com") { req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer") }
        web.load(req)
    }

    func destroy() {
        obs = nil
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.removeFromSuperview()
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if let s = m.body as? String { host?.emitWV(id, "console-message", message: s) }
    }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        host?.emitWV(id, "did-navigate", url: w.url?.absoluteString ?? "")
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        host?.emitWV(id, "dom-ready", url: w.url?.absoluteString ?? "")
    }
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { decisionHandler(.cancel); return }
        let sch = u.scheme ?? ""
        if ["http", "https", "about", "blob", "data"].contains(sch) { decisionHandler(.allow); return }
        if ["mailto", "tel"].contains(sch) { UIApplication.shared.open(u) }
        decisionHandler(.cancel)
    }
    // Los enlaces target=_blank se abren en la misma página (igual que en la versión de escritorio).
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if a.targetFrame == nil { w.load(a.request) }
        return nil
    }
}
