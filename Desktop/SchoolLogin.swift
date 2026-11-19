import SwiftUI
import WebKit

struct SchoolLoginSheet: View {
    @ObservedObject var store: AssignmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var cookies: [[String: Any]] = []
    @State private var pageError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("School Login").font(.headline)
                    Text("Sign in on the school website, then click Save Login.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(store.requesting)
                Button(store.working == "verify" ? "Verifying…" : "Save Login") {
                    store.saveBrowserSession(cookies)
                }
                .disabled(cookies.isEmpty || store.requesting)
            }
            if let error = store.settingsIssue ?? pageError {
                Label(LocalizedStringKey(error), systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            SchoolLoginPage(receive: { cookies = $0 }, fail: { pageError = $0 })
        }
        .padding(14)
        .frame(minWidth: 560, idealWidth: 820, minHeight: 400, idealHeight: 530)
        .interactiveDismissDisabled(store.requesting)
    }
}

private struct SchoolLoginPage: NSViewRepresentable {
    let receive: ([[String: Any]]) -> Void
    let fail: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(receive: receive, fail: fail) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "https://naisstu.schoolis.cn/login")!))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let receive: ([[String: Any]]) -> Void
        let fail: (String?) -> Void

        init(receive: @escaping ([[String: Any]]) -> Void, fail: @escaping (String?) -> Void) {
            self.receive = receive
            self.fail = fail
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url,
                  url.scheme == "https", url.host?.lowercased() == "naisstu.schoolis.cn",
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            receive([])
            fail(nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let page = webView.url, page.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "home" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak webView] cookies in
                guard webView?.url == page else { return }
                self.receive(cookies.compactMap { cookie in
                    let domain = cookie.domain.lowercased()
                    guard ["naisstu.schoolis.cn", ".naisstu.schoolis.cn", ".schoolis.cn"].contains(domain) else { return nil }
                    return ["name": cookie.name, "value": cookie.value, "domain": domain, "path": cookie.path,
                            "secure": cookie.isSecure, "expires": cookie.expiresDate?.timeIntervalSince1970 ?? -1]
                })
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                fail("Could not load the school login page. Check your connection and reopen the login window.")
            }
        }
    }
}
