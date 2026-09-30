//  WindowsRadar.swift
//  Radar de ventanas + navegador flotante integrados.

import SwiftUI
import AppKit
import CoreGraphics
import Combine

// MARK: - Modelo

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let bundleID: String?
    let title: String
    let bounds: CGRect
    let layer: Int
    let sharingState: Int        // 0 = .none, 1 = .readOnly, 2 = .readWrite
}

func sharingName(_ s: Int) -> String {
    switch s {
    case 0:  return "none"
    case 1:  return "readOnly"
    default: return "readWrite"
    }
}

func sharingColor(_ s: Int) -> Color {
    switch s {
    case 0:  return .red
    case 1:  return .orange
    default: return .green
    }
}

// MARK: - Consulta y filtros

enum WindowFilter {
    static func list(minSize: CGFloat) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        let pidToBundle = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
                guard let bid = app.bundleIdentifier else { return nil }
                return (app.processIdentifier, bid)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let regularPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier }
        )

        return raw.compactMap { w -> WindowInfo? in
            guard
                let num   = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid   = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                let b     = w[kCGWindowBounds as String] as? [String: CGFloat],
                let x = b["X"], let y = b["Y"],
                let width = b["Width"], let height = b["Height"]
            else { return nil }

            // Incluir ventanas normales y paneles flotantes (como Floating Browser).
            let normalLayer = Int(NSWindow.Level.normal.rawValue)
            let floatingLayer = Int(NSWindow.Level.floating.rawValue)
            guard (layer == normalLayer || layer == floatingLayer),
                  alpha > 0.01,
                  width >= minSize, height >= minSize,
                  regularPIDs.contains(pid)
            else { return nil }

            let sharing = (w[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? 2

            return WindowInfo(
                id: num,
                ownerPID: pid,
                ownerName: w[kCGWindowOwnerName as String] as? String ?? "",
                bundleID: pidToBundle[pid],
                title: w[kCGWindowName as String] as? String ?? "",
                bounds: CGRect(x: x, y: y, width: width, height: height),
                layer: layer,
                sharingState: sharing
            )
        }
    }
}

// MARK: - Panel con protección de contenido estable

final class ProtectedPanel: NSPanel {

    private(set) var protectionEnabled = true

    // ID que utiliza CoreGraphics / CGWindowList
    var cgWindowID: CGWindowID? {
        guard windowNumber > 0 else { return nil }
        return CGWindowID(windowNumber)
    }

    func setSharingProtection(_ on: Bool) {
        protectionEnabled = on
        reassertProtection()
    }

    func reassertProtection() {
        let defaultSharing: NSWindow.SharingType

        if #available(macOS 15.0, *) {
            defaultSharing = .readOnly
        } else {
            defaultSharing = .readWrite
        }

        let desired: NSWindow.SharingType =
            protectionEnabled ? .none : defaultSharing

        if sharingType != desired {
            sharingType = desired
        }
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStore: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStore,
            defer: flag
        )

        reassertProtection()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        reassertProtection()
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        reassertProtection()
    }

    override func orderBack(_ sender: Any?) {
        super.orderBack(sender)
        reassertProtection()
    }

    override func deminiaturize(_ sender: Any?) {
        super.deminiaturize(sender)
        reassertProtection()
    }

    override func zoom(_ sender: Any?) {
        super.zoom(sender)
        reassertProtection()
    }

    override func becomeKey() {
        super.becomeKey()
        reassertProtection()
    }
}

// MARK: - Registro para reafirmación periódica

final class ProtectionRegistry {
    static let shared = ProtectionRegistry()
    private let table = NSHashTable<ProtectedPanel>.weakObjects()

    func register(_ p: ProtectedPanel) { table.add(p) }
    func reassertAll() { table.allObjects.forEach { $0.reassertProtection() } }
}

// MARK: - Estado en vivo

final class WindowStore: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var events: [String] = []
    @Published var minSize: CGFloat = 80 { didSet { refresh() } }
    @Published var hideProtected = false { didSet { refresh() } }
    @Published var isPaused = false

    let captureAllowed = CGPreflightScreenCaptureAccess()

    private var timer: Timer?
    private var previous: [CGWindowID: WindowInfo] = [:]
    private static var demoWindows: [ProtectedPanel] = []   // solo vida útil

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        // Reafirmar SIEMPRE, incluso con la lista pausada.
        ProtectionRegistry.shared.reassertAll()

        guard !isPaused else { return }

        let fresh = WindowFilter.list(minSize: minSize)
        let visible = hideProtected ? fresh.filter { $0.sharingState != 0 } : fresh
        let sorted = visible.sorted {
            ($0.ownerName.lowercased(), $0.title.lowercased()) <
            ($1.ownerName.lowercased(), $1.title.lowercased())
        }
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })

        var lines: [String] = []

        for w in sorted where previous[w.id] == nil {
            lines.append("[+] \(label(w))")
        }
        for (id, w) in previous where byID[id] == nil {
            lines.append("[-] \(label(w))")
        }
        for (id, w) in byID {
            guard let old = previous[id], old != w else { continue }
            if old.title != w.title {
                lines.append("[~] \(w.ownerName): título \"\(old.title)\" -> \"\(w.title)\"")
            } else if old.bounds != w.bounds {
                if old.bounds.size == w.bounds.size {
                    lines.append("[~] \(w.ownerName): posición \(point(old.bounds.origin)) -> \(point(w.bounds.origin))")
                } else {
                    lines.append("[~] \(w.ownerName): \(size(old.bounds)) -> \(size(w.bounds))")
                }
            } else if old.sharingState != w.sharingState {
                lines.append("[~] \(w.ownerName): sharing \(sharingName(old.sharingState)) -> \(sharingName(w.sharingState))")
            }
        }

        if !lines.isEmpty {
            let stamp = Self.stampFormatter.string(from: Date())
            events.insert(contentsOf: lines.map { "\(stamp)  \($0)" }, at: 0)
            if events.count > 300 { events.removeLast(events.count - 300) }
        }

        previous = byID
        windows = sorted
    }

    func logOwnWindowsFromCGWindowList() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let ownPID = NSRunningApplication.current.processIdentifier

        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            appendDiagnostic("[CGWindowList] La consulta no devolvió una lista.")
            return
        }

        let ownRows = rows.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID
        }

        guard !ownRows.isEmpty else {
            appendDiagnostic("[CGWindowList] Sin ventanas en pantalla para PID=\(ownPID).")
            return
        }

        for row in ownRows {
            let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let title = row[kCGWindowName as String] as? String ?? "(sin título)"
            let owner = row[kCGWindowOwnerName as String] as? String ?? "(app desconocida)"
            let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let sharing = (row[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? -1
            let bounds = row[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = Int(bounds["Width"] ?? 0)
            let height = Int(bounds["Height"] ?? 0)

            appendDiagnostic(
                "[CGWindowList] ID=\(id) PID=\(ownPID) app=\(owner) título=\(title) " +
                "capa=\(layer) sharing=\(sharingName(sharing)) tamaño=\(width)×\(height)"
            )
        }
    }

    private func appendDiagnostic(_ message: String) {
        let stamp = Self.stampFormatter.string(from: Date())
        events.insert("\(stamp)  \(message)", at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
    }

    // Ventana de demostración con sharingType = .none
    func openProtectedWindow() {
        let win = ProtectedPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 210),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Ventana protegida (sharingType = .none)"
        win.setSharingProtection(true)
        win.isReleasedWhenClosed = false

        let text = NSTextField(wrappingLabelWithString:
            "Esta ventana tiene sharingType = .none.\n\n" +
            "Sigue apareciendo en CGWindowList (y en esta tabla), " +
            "pero su contenido sale negro al capturarla.\n\n" +
            "Arrástrala, minímala, zoom o pantalla completa: 'none' se mantiene.")
        text.frame = NSRect(x: 24, y: 24, width: 422, height: 162)
        text.font = .systemFont(ofSize: 14)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 210))
        content.addSubview(text)
        win.contentView = content

        win.center()
        win.makeKeyAndOrderFront(nil)
        ProtectionRegistry.shared.register(win)
        Self.demoWindows.append(win)   // referencia fuerte: evita que ARC la libere
    }

    private func label(_ w: WindowInfo) -> String {
        let t = w.title.isEmpty ? "(sin título)" : w.title
        return "\(w.ownerName) — \(t)"
    }
    private func size(_ r: CGRect) -> String { "\(Int(r.width))×\(Int(r.height))" }
    private func point(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
}
