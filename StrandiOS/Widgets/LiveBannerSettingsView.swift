import SwiftUI
import StrandDesign

/// Pick and order what the Lock Screen / Dynamic Island banner shows.
struct LiveBannerSettingsView: View {
    @State private var fields: [LiveBannerField] = LiveBannerPrefs.load()

    private var available: [LiveBannerField] {
        LiveBannerField.allCases.filter { !fields.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(fields, id: \.self) { f in
                    row(f, index: fields.firstIndex(of: f) ?? 0)
                }
                .onMove { from, to in
                    fields.move(fromOffsets: from, toOffset: to)
                    save()
                }
                .onDelete { idx in
                    guard fields.count - idx.count >= 1 else { return }
                    fields.remove(atOffsets: idx)
                    save()
                }
            } header: {
                Text("Showing")
            } footer: {
                Text("Drag to reorder. The top one shows big and in the Dynamic Island. Up to \(LiveBannerPrefs.maxFields). Workout, Rest and Sets only appear while a workout is running, and the timers keep counting on the Lock Screen.")
            }

            if fields.count < LiveBannerPrefs.maxFields, !available.isEmpty {
                Section("Add") {
                    ForEach(available, id: \.self) { f in
                        Button {
                            fields.append(f)
                            save()
                        } label: {
                            Label(LocalizedStringKey(f.label), systemImage: f.symbol)
                        }
                    }
                }
            }

            Section {
                Button("Back to heart rate, Charge, Effort") {
                    fields = LiveBannerPrefs.defaultFields
                    save()
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Lock Screen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ f: LiveBannerField, index: Int) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: f.symbol)
                .foregroundStyle(f == .heartRate ? StrandPalette.statusCritical : StrandPalette.accent)
                .frame(width: 24)
            Text(LocalizedStringKey(f.label))
                .font(StrandFont.subhead)
            if index == 0 {
                Spacer()
                Text("Big")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func save() { LiveBannerPrefs.save(fields) }
}
