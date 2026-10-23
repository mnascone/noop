import SwiftUI
import StrandDesign

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

    var body: some View {
        List {
            Section {
                Toggle("Show the live banner", isOn: $enabled)
            } footer: {
                Text("Shows on the Lock Screen and in the Dynamic Island while the strap is connected.")
            }

            if enabled {
                fieldSection(String(localized: "Showing"), $fields, allowWorkoutOnly: true,
                             footer: String(localized: "Drag to reorder. Up to \(LiveBannerPrefs.maxFields). Workout, Rest and Sets only show while a workout runs, and their timers keep counting on the Lock Screen."))
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
                    fieldSection(String(localized: "During a workout"), $workoutFields, allowWorkoutOnly: true,
                                 footer: nil) { LiveBannerPrefs.saveWorkout(workoutFields) }
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
                        ForEach(LiveBannerField.allCases, id: \.rawValue) { f in
                            Label(LocalizedStringKey(f.label), systemImage: f.symbol).tag(f.rawValue)
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
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Lock Screen")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func fieldSection(_ header: String, _ list: Binding<[LiveBannerField]>, allowWorkoutOnly: Bool,
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
                Menu {
                    ForEach(LiveBannerField.allCases.filter { !list.wrappedValue.contains($0) }, id: \.self) { f in
                        Button {
                            list.wrappedValue.append(f)
                            save()
                        } label: {
                            Label(LocalizedStringKey(f.label), systemImage: f.symbol)
                        }
                    }
                } label: {
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
                .foregroundStyle(f == .heartRate || f == .zone ? StrandPalette.statusCritical : StrandPalette.accent)
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
