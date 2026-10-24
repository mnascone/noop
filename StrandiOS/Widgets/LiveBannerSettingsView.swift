import SwiftUI
import StrandDesign
import UIKit

/// Everything about the Lock Screen / Dynamic Island banner: which fields, their order, a separate set for
/// workouts, layout, labels, title, and the Dynamic Island's field.
struct LiveBannerSettingsView: View {
    @State private var fields: [LiveBannerField] = LiveBannerPrefs.load()
    @State private var workoutFields: [LiveBannerField] = LiveBannerPrefs.loadWorkout() ?? LiveBannerPrefs.defaultWorkoutFields
    @State private var separateWorkout: Bool = LiveBannerPrefs.loadWorkout() != nil
    @AppStorage(LiveBannerPrefs.layoutKey) private var layoutRaw = LiveBannerLayout.featured.rawValue
    @AppStorage(LiveBannerPrefs.showLabelsKey) private var showLabels = true
    @AppStorage(LiveBannerPrefs.titleKey) private var title = ""
    @AppStorage(LiveBannerPrefs.islandFieldKey) private var islandRaw = ""
    @AppStorage(UnitPrefs.liveActivityKey) private var enabled = true
    /// Which list "Add a field" is adding to. A full sheet instead of a pop-up menu: thirty-odd fields in
    /// grouped sections overflowed the menu, which then couldn't scroll.
    @State private var addingTo: AddTarget?

    enum AddTarget: String, Identifiable {
        case main, workout
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                Toggle("Show the live banner", isOn: $enabled)
            } footer: {
                Text("Shows on the Lock Screen and in the Dynamic Island while the strap is connected.")
            }

            if enabled {
                fieldSection(String(localized: "Showing"), $fields, target: .main, allowWorkoutOnly: true,
                             footer: String(localized: "Drag to reorder. Up to \(LiveBannerPrefs.maxFields). Workout fields (timers, sets, distance and so on) only show while a workout runs, and the timers keep counting on the Lock Screen."))
                    { LiveBannerPrefs.save(fields) }

                Section {
                    Toggle("Different fields during workouts", isOn: $separateWorkout)
                        .onChange(of: separateWorkout) { _, on in
                            LiveBannerPrefs.saveWorkout(on ? workoutFields : nil)
                        }
                } footer: {
                    Text("Swap to a workout set, like rest timer, heart rate and sets, while a workout runs. Back to the normal set when it ends.")
                }
                if separateWorkout {
                    fieldSection(String(localized: "During a workout"), $workoutFields, target: .workout, allowWorkoutOnly: true,
                                 footer: nil) { LiveBannerPrefs.saveWorkout(workoutFields) }
                }

                Section {
                    ForEach(colorFields, id: \.self) { f in
                        ColorPicker(selection: colorBinding(f), supportsOpacity: false) {
                            Label {
                                Text(LocalizedStringKey(f.label))
                            } icon: {
                                Image(systemName: f.symbol).foregroundStyle(color(f))
                            }
                        }
                    }
                    if !colorOverrides.isEmpty {
                        Button("Reset colours") {
                            colorOverrides = [:]
                            UserDefaults.standard.removeObject(forKey: LiveBannerPrefs.colorsKey)
                        }
                    }
                } header: {
                    Text("Icon colours")
                } footer: {
                    Text("Each field has its own colour. Tap one to change it.")
                }

                Section("Look") {
                    Picker("Layout", selection: $layoutRaw) {
                        ForEach(LiveBannerLayout.allCases, id: \.rawValue) { l in
                            Text(LocalizedStringKey(l.label)).tag(l.rawValue)
                        }
                    }
                    Toggle("Show labels", isOn: $showLabels)
                    TextField("Title (blank = automatic)", text: $title)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    Picker("Dynamic Island shows", selection: $islandRaw) {
                        Text("Same as the first field").tag("")
                        ForEach(Self.groups, id: \.self) { group in
                            Section(LocalizedStringKey(group)) {
                                ForEach(LiveBannerField.allCases.filter { $0.group == group }, id: \.rawValue) { f in
                                    Label(LocalizedStringKey(f.label), systemImage: f.symbol).tag(f.rawValue)
                                }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Dynamic Island")
                } footer: {
                    Text("The small view around the camera. The next two fields show when you press and hold it.")
                }

                Section {
                    Button("Reset to heart rate, Charge, Effort") {
                        fields = LiveBannerPrefs.defaultFields
                        LiveBannerPrefs.save(fields)
                        separateWorkout = false
                        LiveBannerPrefs.saveWorkout(nil)
                        layoutRaw = LiveBannerLayout.featured.rawValue
                        showLabels = true
                        title = ""
                        islandRaw = ""
                        colorOverrides = [:]
                        UserDefaults.standard.removeObject(forKey: LiveBannerPrefs.colorsKey)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .sheet(item: $addingTo) { target in
            BannerFieldPickerSheet(taken: target == .main ? fields : workoutFields) { f in
                if target == .main {
                    fields.append(f)
                    LiveBannerPrefs.save(fields)
                } else {
                    workoutFields.append(f)
                    LiveBannerPrefs.saveWorkout(workoutFields)
                }
            }
        }
        .navigationTitle("Lock Screen")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let groups = ["Live", "Today", "Last night", "WHOOP strap", "Workout"]

    @State private var colorOverrides: [String: String] = LiveBannerPrefs.colors()

    /// The fields on show in either set, each once.
    private var colorFields: [LiveBannerField] {
        var seen = Set<LiveBannerField>()
        return (fields + (separateWorkout ? workoutFields : [])).filter { seen.insert($0).inserted }
    }

    private func color(_ f: LiveBannerField) -> Color {
        Self.hexColor(LiveBannerPrefs.colorHex(f, overrides: colorOverrides))
    }

    private func colorBinding(_ f: LiveBannerField) -> Binding<Color> {
        Binding(get: { color(f) }, set: { c in
            guard let hex = Self.hex(c) else { return }
            let value: String? = hex == f.defaultColorHex ? nil : hex
            colorOverrides[f.rawValue] = value
            LiveBannerPrefs.setColor(value, for: f)
        })
    }

    static func hexColor(_ hex: String) -> Color {
        let v = UInt32(hex, radix: 16) ?? 0x0A84FF
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    static func hex(_ c: Color) -> String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ x: CGFloat) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    @ViewBuilder
    private func fieldSection(_ header: String, _ list: Binding<[LiveBannerField]>, target: AddTarget,
                              allowWorkoutOnly: Bool,
                              footer: String?, save: @escaping () -> Void) -> some View {
        Section {
            ForEach(list.wrappedValue, id: \.self) { f in
                row(f, first: list.wrappedValue.first == f)
            }
            .onMove { from, to in
                list.wrappedValue.move(fromOffsets: from, toOffset: to)
                save()
            }
            .onDelete { idx in
                guard list.wrappedValue.count - idx.count >= 1 else { return }
                list.wrappedValue.remove(atOffsets: idx)
                save()
            }
            if list.wrappedValue.count < LiveBannerPrefs.maxFields {
                Button { addingTo = target } label: {
                    Label("Add a field", systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text(header)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func row(_ f: LiveBannerField, first: Bool) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: f.symbol)
                .foregroundStyle(color(f))
                .frame(width: 24)
            Text(LocalizedStringKey(f.label))
                .font(StrandFont.subhead)
            if first, layoutRaw == LiveBannerLayout.featured.rawValue {
                Spacer()
                Text("Big")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

/// Every banner field, grouped, in a scrolling list. Tapping one adds it and closes the sheet.
private struct BannerFieldPickerSheet: View {
    let taken: [LiveBannerField]
    let onPick: (LiveBannerField) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(LiveBannerSettingsView.groups, id: \.self) { group in
                    let options = LiveBannerField.allCases.filter { $0.group == group && !taken.contains($0) }
                    if !options.isEmpty {
                        Section(LocalizedStringKey(group)) {
                            ForEach(options, id: \.rawValue) { f in
                                Button {
                                    onPick(f)
                                    dismiss()
                                } label: {
                                    Label(LocalizedStringKey(f.label), systemImage: f.symbol)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.inactive))
            .navigationTitle("Add a field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
