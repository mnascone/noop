import Foundation
import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics

/// Push / pull / legs per exercise, kept on this device by exercise name. An exercise you haven't set
/// gets a default from its name or its primary muscle (`StrengthCategory.guess`); setting one stores it,
/// and every set of that exercise, in any workout, inherits it. One workout can mix all three.
@MainActor
final class ExerciseCategoryStore: ObservableObject {
    static let shared = ExerciseCategoryStore()
    private static let key = "noop.exerciseCategories.v1"
    /// Stored for an exercise you set to none, so a default doesn't come back.
    private static let none = "none"

    private static let regionsKey = "noop.exerciseRegions.v1"
    private static let namesKey = "noop.exerciseNames.v1"

    /// Lower-cased name → category raw value (or "none").
    @Published private(set) var stored: [String: String]
    /// Lower-cased name → the Lift Log's primary-muscle region, for the default of an exercise whose name
    /// doesn't say.
    private var regions: [String: String]
    /// Exercise names as you wrote them, most recent first, for the sets editor's exercise menu.
    @Published private(set) var recentNames: [String]

    private init() {
        stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        regions = UserDefaults.standard.dictionary(forKey: Self.regionsKey) as? [String: String] ?? [:]
        recentNames = UserDefaults.standard.stringArray(forKey: Self.namesKey) ?? []
    }

    /// The category an exercise counts as: yours if set, else the default.
    func category(for name: String, primaryRegion: String? = nil) -> StrengthCategory? {
        let k = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let raw = stored[k] { return StrengthCategory(rawValue: raw) }
        return StrengthCategory.guess(name: name, primaryRegion: primaryRegion ?? regions[k])
    }

    /// Remember an exercise seen in the Lift Log or named in the editor: its spelling for the menu, and
    /// its primary muscle's region for its default category.
    func note(_ name: String, region: String? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let k = clean.lowercased()
        if let region, regions[k] != region {
            regions[k] = region
            UserDefaults.standard.set(regions, forKey: Self.regionsKey)
        }
        var names = recentNames.filter { $0.lowercased() != k }
        names.insert(clean, at: 0)
        names = Array(names.prefix(60))
        if names != recentNames {
            recentNames = names
            UserDefaults.standard.set(names, forKey: Self.namesKey)
        }
    }

    /// True when the exercise's category is a default rather than one you chose.
    func isDefault(_ name: String) -> Bool { stored[name.lowercased()] == nil }

    func set(_ c: StrengthCategory?, for name: String) {
        let k = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return }
        stored[k] = c?.rawValue ?? Self.none
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    /// For code that isn't observing: the same answer.
    static func category(for name: String) -> StrengthCategory? { shared.category(for: name) }
}

extension StrengthCategory {
    var displayName: String {
        switch self {
        case .push: return String(localized: "Push")
        case .pull: return String(localized: "Pull")
        case .legs: return String(localized: "Legs")
        }
    }

    var color: Color {
        switch self {
        case .push: return StrandPalette.metricRose
        case .pull: return StrandPalette.accent
        case .legs: return StrandPalette.metricAmber
        }
    }
}

/// The quick Push / Pull / Legs choice for one exercise: three chips, one tap, remembered by name.
struct StrengthCategoryPicker: View {
    let exercise: String
    var primaryRegion: String? = nil
    @ObservedObject private var store = ExerciseCategoryStore.shared

    var body: some View {
        let current = store.category(for: exercise, primaryRegion: primaryRegion)
        HStack(spacing: 6) {
            ForEach(StrengthCategory.allCases, id: \.self) { c in
                Button {
                    store.set(current == c && !store.isDefault(exercise) ? nil : c, for: exercise)
                } label: {
                    Text(c.displayName)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(current == c ? Color.white : StrandPalette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(current == c ? c.color : StrandPalette.surfaceInset))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == c ? [.isSelected] : [])
            }
            if current != nil, store.isDefault(exercise) {
                Text("default")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .disabled(exercise.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(exercise.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
    }
}

/// A small coloured tag: "Push".
struct StrengthCategoryTag: View {
    let category: StrengthCategory
    var body: some View {
        Text(category.displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(category.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(category.color.opacity(0.14)))
    }
}

/// "Push 3 · Pull 2 · Legs 4" as coloured tags.
struct CategoryCounts: View {
    let counts: [StrengthCategory: Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(StrengthCategory.allCases, id: \.self) { c in
                if let n = counts[c], n > 0 {
                    HStack(spacing: 3) {
                        StrengthCategoryTag(category: c)
                        Text("\(n)")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }
}
