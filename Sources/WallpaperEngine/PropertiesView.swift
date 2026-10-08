import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Property Store

/// Observable model that holds the live property values for the properties panel.
final class PropertyStore: ObservableObject {
    let properties: [WallpaperProperty]
    let propertiesByKey: [String: WallpaperProperty]
    let sections: [PropertySection]
    @Published var values: [String: String]
    let onChange: (String, String) -> Void
    let onReset: (() -> Bool)?

    init(properties: [WallpaperProperty],
         values: [String: String],
         onChange: @escaping (String, String) -> Void,
         onReset: (() -> Bool)? = nil) {
        self.properties = properties
        self.propertiesByKey = Dictionary(properties.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.sections = PropertyLayout.sections(properties)
        self.onChange   = onChange
        self.onReset = onReset
        // Seed values: use provided entry or fall back to property default
        var merged = [String: String]()
        for p in properties where p.type.holdsValue { merged[p.key] = values[p.key] ?? p.defaultValue }
        self.values = merged
    }

    var hasEditableProperties: Bool { properties.contains { $0.type.holdsValue } }

    func set(_ value: String, for key: String) {
        values[key] = value
        onChange(key, value)
    }

    func isVisible(_ property: WallpaperProperty) -> Bool {
        WallpaperProperty.isVisible(property, among: propertiesByKey, values: values)
    }

    func isModified(_ property: WallpaperProperty) -> Bool {
        property.type.holdsValue && (values[property.key] ?? property.defaultValue) != property.defaultValue
    }

    func reset(_ property: WallpaperProperty) {
        set(property.defaultValue, for: property.key)
    }

    func resetToDefaults() {
        if let onReset, !onReset() { return }
        for p in properties where p.type.holdsValue {
            values[p.key] = p.defaultValue
            if onReset == nil { onChange(p.key, p.defaultValue) }
        }
    }
}

// MARK: - Sections

/// The property controls for one wallpaper, as `Section`s for use inside a `Form`.
/// Group headers collapse; rows whose `condition` fails are hidden.
struct PropertySections: View {
    @ObservedObject var store: PropertyStore
    @State private var collapsedSections: Set<String> = []

    var body: some View {
        ForEach(store.sections) { section in
            let visible = section.items.filter(store.isVisible)
            if !visible.isEmpty {
                if let header = section.header, store.isVisible(header) {
                    Section(isExpanded: expansion(for: section.id)) {
                        rows(visible)
                    } header: {
                        Text(PropertyLayout.labelText(header.text).map { String($0.characters) } ?? header.key)
                    }
                } else {
                    Section { rows(visible) }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ properties: [WallpaperProperty]) -> some View {
        ForEach(properties) { prop in
            if prop.type.holdsValue {
                PropertyRow(prop: prop, store: store)
            } else if let label = PropertyLayout.labelText(prop.text) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(id) },
            set: { expanded in
                if expanded { collapsedSections.remove(id) } else { collapsedSections.insert(id) }
            }
        )
    }
}

// MARK: - Property Row

private struct PropertyRow: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                control
                    .frame(maxWidth: 240)
                Button {
                    store.reset(prop)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
                .opacity(store.isModified(prop) ? 1 : 0)
                .disabled(!store.isModified(prop))
                .accessibilityHidden(!store.isModified(prop))
            }
        } label: {
            Text(PropertyLayout.labelText(prop.text).map { String($0.characters) } ?? prop.key)
                .lineLimit(2)
        }
        .contextMenu {
            Button("Reset to Default") { store.reset(prop) }
                .disabled(!store.isModified(prop))
        }
    }

    @ViewBuilder
    private var control: some View {
        switch prop.type {
        case .slider:       SliderControl(prop: prop, store: store)
        case .bool:         BoolControl(prop: prop, store: store)
        case .color:        ColorControl(prop: prop, store: store)
        case .combo:        ComboControl(prop: prop, store: store)
        case .textinput:    TextControl(prop: prop, store: store)
        case .file,
             .scenetexture: FileControl(prop: prop, store: store)
        case .text, .group, .usershortcut: EmptyView()
        }
    }
}

// MARK: - Individual Controls

private struct SliderControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    // Some authored sliders list their endpoints in descending order. SwiftUI
    // requires an ascending range; keep the original metadata and value intact.
    private var lo: Double { min(prop.min ?? 0, prop.max ?? 1) }
    private var hi: Double { max(prop.min ?? 0, prop.max ?? 1) }
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
            if lo == hi {
                // There is no editable range, and a stepped zero-length slider
                // traps inside SwiftUI. Preserve the value in a disabled control.
                Slider(value: .constant(lo), in: lo...hi).disabled(true)
            } else {
                Slider(value: binding, in: lo...hi, step: stride)
            }
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

private struct FileControl: View {
    let prop: WallpaperProperty
    @ObservedObject var store: PropertyStore

    private var path: String { store.values[prop.key] ?? prop.defaultValue }

    var body: some View {
        HStack(spacing: 6) {
            Text(path.isEmpty ? "None" : (path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .help(path)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Button("Choose…", action: choose)
            if !path.isEmpty {
                Button {
                    store.set("", for: prop.key)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear")
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if prop.type == .scenetexture { panel.allowedContentTypes = [.image] }
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.set(url.path, for: prop.key)
    }
}
