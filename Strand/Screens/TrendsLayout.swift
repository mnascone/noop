import SwiftUI
import StrandDesign

/// The Trends cards the user can reorder and hide. Raw values are stored, so they never change.
enum TrendsSection: String, CaseIterable, Identifiable {
    case weekly, trio, pacing, charge, multiples, trainingLoad, year, report
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .weekly: return "Week in review"
        case .trio: return "Charge, Effort, Rest"
        case .pacing: return "Charge vs Effort dial"
        case .charge: return "Charge over time"
        case .multiples: return "HRV, resting HR, Effort"
        case .trainingLoad: return "Training load"
        case .year: return "Charge calendar"
        case .report: return "Export report"
        }
    }
}

enum TrendsLayoutPrefs {
    static let orderKey = "noop.trends.order"
    static let hiddenKey = "noop.trends.hidden"
    static let defaultOrder: [TrendsSection] = [.weekly, .trio, .pacing, .charge, .multiples,
                                                .trainingLoad, .year, .report]

    /// Saved order, with any card added since appended in its default place.
    static func order(_ raw: String) -> [TrendsSection] {
        var out = raw.split(separator: ",").compactMap { TrendsSection(rawValue: String($0)) }
        var seen = Set(out)
        for s in defaultOrder where !seen.contains(s) {
            let idx = defaultOrder.firstIndex(of: s).map { min($0, out.count) } ?? out.count
            out.insert(s, at: idx)
            seen.insert(s)
        }
        return out
    }

    static func hidden(_ raw: String) -> Set<TrendsSection> {
        Set(raw.split(separator: ",").compactMap { TrendsSection(rawValue: String($0)) })
    }

    static func encode<S: Sequence>(_ s: S) -> String where S.Element == TrendsSection {
        s.map(\.rawValue).joined(separator: ",")
    }
}

/// Reorder and hide the Trends cards.
struct TrendsLayoutEditor: View {
    @AppStorage(TrendsLayoutPrefs.orderKey) private var orderRaw = ""
    @AppStorage(TrendsLayoutPrefs.hiddenKey) private var hiddenRaw = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let order = TrendsLayoutPrefs.order(orderRaw)
        let hidden = TrendsLayoutPrefs.hidden(hiddenRaw)
        NavigationStack {
            List {
                Section {
                    ForEach(order) { s in
                        Toggle(isOn: Binding(
                            get: { !hidden.contains(s) },
                            set: { on in
                                var h = hidden
                                if on { h.remove(s) } else { h.insert(s) }
                                hiddenRaw = TrendsLayoutPrefs.encode(TrendsSection.allCases.filter(h.contains))
                            })) {
                            Text(s.title)
                        }
                    }
                    .onMove { from, to in
                        var o = order
                        o.move(fromOffsets: from, toOffset: to)
                        orderRaw = TrendsLayoutPrefs.encode(o)
                    }
                } footer: {
                    Text("Drag to reorder. Switch off what you don't want to see.")
                }
                Section {
                    Button("Reset to default") {
                        orderRaw = ""
                        hiddenRaw = ""
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Edit Trends")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
