//  FloatingBrowser.swift
//  Navegador flotante integrado con el radar.

import Cocoa
import SwiftUI
import WebKit
import Combine
import Carbon.HIToolbox

// MARK: - WebViewStore

final class WebViewStore: ObservableObject {
    let webView = WKWebView(frame: .zero)
    @Published var urlString = "https://chatgpt.com"
    private var loadedInitialPage = false

    func loadInitialPageIfNeeded() {
        guard !loadedInitialPage else { return }
        loadedInitialPage = true
        load()
    }

    func load() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    func snapshotToDesktop() {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { image, error in
            guard error == nil, let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }

            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let fileURL = desktop.appendingPathComponent("FloatingBrowser_\(formatter.string(from: Date())).png")
            try? png.write(to: fileURL)
            NSSound(named: "Glass")?.play()
        }
    }
}

final class BrowserHostStore: ObservableObject {
    static let shared = BrowserHostStore()

    @Published var showingBrowser = true
    @Published var windowOpacity = 1.0
    @Published var alwaysOnTop = true
    @Published private(set) var isWindowVisible = true
    let webViewStore = WebViewStore()
    private weak var hostWindow: NSWindow?

    func attach(window: NSWindow) {
        hostWindow = window
        applyWindowSettings()
    }

    func applyWindowSettings() {
        guard let hostWindow else { return }
        hostWindow.sharingType = .none
        hostWindow.alphaValue = CGFloat(windowOpacity)
        hostWindow.level = alwaysOnTop ? .floating : .normal
        hostWindow.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        isWindowVisible = hostWindow.isVisible
    }

    func setWindowOpacity(_ value: Double) {
        let clampedValue = min(max(value, 0.25), 1.0)
        windowOpacity = clampedValue
        hostWindow?.alphaValue = CGFloat(clampedValue)
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        alwaysOnTop = enabled
        hostWindow?.level = enabled ? .floating : .normal
    }

    func toggleWindowVisibility() {
        guard let hostWindow else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if hostWindow.isVisible {
            hostWindow.orderOut(nil)
            isWindowVisible = false
        } else {
            applyWindowSettings()
            NSApp.activate(ignoringOtherApps: true)
            hostWindow.makeKeyAndOrderFront(nil)
            isWindowVisible = true
        }
    }

    func captureBrowserSnapshot() {
        showingBrowser = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.webViewStore.snapshotToDesktop()
        }
    }
}

// MARK: - Vista del navegador

struct FloatingBrowserView: View {
    @ObservedObject var store: WebViewStore

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button("◀") { store.goBack() }
                Button("▶") { store.goForward() }
                Button("⟳") { store.reload() }

                TextField("Enter URL (https://...)", text: $store.urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit { store.load() }

                Button("Go") { store.load() }
            }
            .padding(10)

            WebViewRepresentable(store: store)
                .frame(minWidth: 520, minHeight: 580)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { store.loadInitialPageIfNeeded() }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var store: WebViewStore

    func makeNSView(context: Context) -> WKWebView { store.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// Configura el único NSWindow anfitrión del navegador y el radar.
struct WindowSharingProtectionAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SharingProtectionView()
        view.frame = .zero
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            BrowserHostStore.shared.attach(window: window)
        }
    }

    private final class SharingProtectionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                BrowserHostStore.shared.attach(window: window)
            }
        }
    }
}

// MARK: - Atajo global (Carbon, API pública)

final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var handler: (() -> Void)?

    func register(keyCode: Int, modifiers: Int) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                me.handler?()
                return noErr
            },
            1, &eventType, userData, &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x46424F58), id: 1)   // 'FBOX'
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    deinit {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        if let h = eventHandlerRef { RemoveEventHandler(h) }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hotkey = GlobalHotkey()
        hotkey.handler = {
            DispatchQueue.main.async { BrowserHostStore.shared.toggleWindowVisibility() }
        }
        hotkey.register(keyCode: Int(kVK_Space), modifiers: cmdKey | optionKey)
        self.hotkey = hotkey
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Ocultar la ventana (⌘1) no debe cerrar el proceso de la app.
        false
    }
}
