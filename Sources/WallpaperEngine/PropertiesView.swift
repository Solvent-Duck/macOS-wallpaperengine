import AppKit
import SwiftUI

// MARK: - Property Store

/// Observable model that holds the live property values for the properties panel.
final class PropertyStore: ObservableObject {
    let properties: [WallpaperProperty]
    @Published var values: [String: String]
    let onChange: (String, String) -> Void

    init(properties: [WallpaperProperty],
         values: [String: String],
         onChange: @escaping (String, String) -> Void) {
        self.properties = properties
        self.onChange   = onChange
        // Seed values: use provided entry or fall back to property default
        var merged = [String: String]()
        for p in properties { merged[p.key] = values[p.key] ?? p.defaultValue }
        self.values = merged
    }

    func set(_ value: String, for key: String) {
        values[key] = value
        onChange(key, value)
    }

    func resetToDefaults() {
        for p in properties {
            values[p.key] = p.defaultValue
            onChange(p.key, p.defaultValue)
        }
    }
}

// MARK: - Root View

struct PropertiesView: View {
    @ObservedObject var store: PropertyStore

    var editableProperties: [WallpaperProperty] {
        store.properties.filter { $0.type != .text }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.properties.isEmpty {
                emptyState
            } else {
                propertyList
            }

            Divider()

            HStack {
                Spacer()
                Button("Reset to Defaults") { store.resetToDefaults() }
                    .disabled(editableProperties.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 360, idealWidth: 400, minHeight: 160)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No configurable properties")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var propertyList: some View {
        List(store.properties) { prop in
            if prop.type == .text {
                Text(prop.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                PropertyRow(prop: prop, store: store)
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Property Row

private struct PropertyRow: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(prop.text)
                .frame(minWidth: 80, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            control
                .frame(maxWidth: 220)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var control: some View {
        switch prop.type {
        case .slider:      SliderControl(prop: prop, store: store)
        case .bool:        BoolControl(prop: prop, store: store)
        case .color:       ColorControl(prop: prop, store: store)
        case .combo:       ComboControl(prop: prop, store: store)
        case .textinput,
             .file,
             .scenetexture: TextControl(prop: prop, store: store)
        case .text:        EmptyView()
        }
    }
}

// MARK: - Individual Controls

private struct SliderControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    private var lo: Double { prop.min ?? 0 }
    private var hi: Double { prop.max ?? 1 }
    private var stride: Double { prop.step ?? max((hi - lo) / 100, 0.001) }
    private var decimals: Int { prop.precision ?? 2 }

    private var binding: Binding<Double> {
        Binding(
            get: { Double(store.values[prop.key] ?? prop.defaultValue) ?? lo },
            set: { store.set(String(format: "%g", $0), for: prop.key) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: binding, in: lo...hi, step: stride)
            Text(String(format: "%.\(decimals)f", binding.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
    }
}

private struct BoolControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    private var binding: Binding<Bool> {
        Binding(
            get: { store.values[prop.key] == "1" },
            set: { store.set($0 ? "1" : "0", for: prop.key) }
        )
    }

    var body: some View {
        Toggle("", isOn: binding).labelsHidden()
    }
}

private struct ColorControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    private var binding: Binding<Color> {
        Binding(
            get: {
                let s = store.values[prop.key] ?? prop.defaultValue
                if let (r, g, b) = WallpaperProperty.colorComponents(from: s) {
                    return Color(red: r, green: g, blue: b)
                }
                return .white
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                store.set(WallpaperProperty.colorString(
                    r: Double(ns.redComponent),
                    g: Double(ns.greenComponent),
                    b: Double(ns.blueComponent)
                ), for: prop.key)
            }
        )
    }

    var body: some View {
        ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden()
    }
}

private struct ComboControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    private var binding: Binding<String> {
        Binding(
            get: { store.values[prop.key] ?? prop.defaultValue },
            set: { store.set($0, for: prop.key) }
        )
    }

    var body: some View {
        Picker("", selection: binding) {
            ForEach(prop.options ?? [], id: \.value) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

private struct TextControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    private var binding: Binding<String> {
        Binding(
            get: { store.values[prop.key] ?? prop.defaultValue },
            set: { store.set($0, for: prop.key) }
        )
    }

    var body: some View {
        TextField("", text: binding)
            .textFieldStyle(.roundedBorder)
    }
}

// MARK: - Window Controller

/// Manages the floating properties panel. Owned by AppDelegate.
final class PropertiesWindowController: NSObject {
    private var panel: NSPanel?

    /// Show (or update) the properties panel for the current wallpaper.
    func show(title: String,
              properties: [WallpaperProperty],
              values: [String: String],
              onChange: @escaping (String, String) -> Void) {
        let store = PropertyStore(properties: properties, values: values, onChange: onChange)
        let rootView = PropertiesView(store: store)
        let vc = NSHostingController(rootView: rootView)

        if let existing = panel {
            existing.title = "Properties — \(title)"
            existing.contentViewController = vc
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask:   [.titled, .closable, .resizable, .utilityWindow],
            backing:     .buffered,
            defer:       false
        )
        p.title              = "Properties — \(title)"
        p.isFloatingPanel    = true
        p.hidesOnDeactivate  = false
        p.isReleasedWhenClosed = false
        p.contentViewController = vc
        p.center()

        self.panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
    }
}
