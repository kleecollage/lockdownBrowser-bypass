import SwiftUI

// MARK: - Vista Principal (ContentView)

struct ContentView: View {
    @StateObject private var store = WindowStore()
    @StateObject private var browser = BrowserHostStore.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(browser.isWindowVisible ? "Ocultar ventana" : "Mostrar ventana") {
                    browser.toggleWindowVisibility()
                }

                Text("Opacidad")
                    .font(.caption)
                Slider(
                    value: Binding(
                        get: { browser.windowOpacity },
                        set: { browser.setWindowOpacity($0) }
                    ),
                    in: 0.25...1.0
                )
                    .frame(width: 110)
                Text("\(Int(browser.windowOpacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)

                Toggle(
                    "Siempre arriba",
                    isOn: Binding(
                        get: { browser.alwaysOnTop },
                        set: { browser.setAlwaysOnTop($0) }
                    )
                )
                    .toggleStyle(.checkbox)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Picker("Vista", selection: $browser.showingBrowser) {
                Text("Navegador").tag(true)
                Text("Radar").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.bottom, 4)

            if browser.showingBrowser {
                FloatingBrowserView(store: browser.webViewStore)
                    .frame(minWidth: 520, minHeight: 620)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                radarContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 680)
        // El navegador y el radar ahora comparten un único NSWindow.
        .background(WindowSharingProtectionAccessor().frame(width: 0, height: 0))
        .onAppear { store.start() }
    }

    private var radarContent: some View {
        VStack(spacing: 0) {
            if !store.captureAllowed {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Permiso de grabación de pantalla no otorgado. Algunos títulos de ventana pueden no estar disponibles.")
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(Color.yellow.opacity(0.15))
            }

            // Barra de controles
            HStack(spacing: 16) {
                Button(action: { store.isPaused.toggle() }) {
                    Label(store.isPaused ? "Reanudar" : "Pausar", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                }

                Toggle("Ocultar protegidas", isOn: $store.hideProtected)
                    .toggleStyle(.checkbox)

                HStack(spacing: 4) {
                    Text("Tam. mín:")
                        .font(.caption)
                    Slider(value: $store.minSize, in: 0...500, step: 10) {
                        Text("Tamaño mínimo")
                    }
                    .frame(width: 100)
                    Text("\(Int(store.minSize))px")
                        .font(.caption)
                        .monospacedDigit()
                }

                Spacer()

                Button("Abrir ventana protegida") {
                    store.openProtectedWindow()
                }
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Selector de vista: Tabla de Ventanas / Log de Eventos
            Picker("", selection: $selectedTab) {
                Text("Ventanas (\(store.windows.count))").tag(0)
                Text("Eventos (\(store.events.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(8)

            if selectedTab == 0 {
                windowTable
            } else {
                eventLogList
            }
        }
    }

    private var windowTable: some View {
        Table(store.windows) {
            TableColumn("App") { w in
                Text(w.ownerName)
                    .bold()
            }
            TableColumn("PID") { w in
                Text("\(w.ownerPID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            TableColumn("Título") { w in
                Text(w.title.isEmpty ? "(sin título)" : w.title)
            }
            TableColumn("Dimensiones") { w in
                Text("\(Int(w.bounds.width))×\(Int(w.bounds.height)) (\(Int(w.bounds.origin.x)), \(Int(w.bounds.origin.y)))")
                    .font(.caption)
                    .monospacedDigit()
            }
            TableColumn("Capa") { w in
                Text("\(w.layer)")
                    .font(.caption)
                    .monospacedDigit()
            }
            TableColumn("Sharing State") { w in
                HStack(spacing: 4) {
                    Circle()
                        .fill(sharingColor(w.sharingState))
                        .frame(width: 8, height: 8)
                    Text(sharingName(w.sharingState))
                        .font(.caption)
                }
            }
        }
    }

    private var eventLogList: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Consultar CGWindowList para esta app") {
                    store.logOwnWindowsFromCGWindowList()
                }
                Spacer()
            }
            .padding(8)

            List(store.events, id: \.self) { event in
                Text(event)
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }
}

// MARK: - Punto de entrada

@main
struct RadarVentanasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Radar de ventanas") {
            ContentView()
        }
        .commands {
            CommandMenu("Floating Browser") {
                Button("Ocultar/Mostrar ventana") {
                    BrowserHostStore.shared.toggleWindowVisibility()
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Guardar captura del navegador") {
                    BrowserHostStore.shared.captureBrowserSnapshot()
                }
                .keyboardShortcut("3", modifiers: [.command])
            }
        }
    }
}
