import Foundation
import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics

/// The kinds of strength work you sort workouts, exercises and sets into: subcategories of strength.
/// Push, Pull, Legs, Abs and Accessory to begin with; add your own, delete any (built-ins included,
/// and they can be added back by name). Kept on this device, in your order.
@MainActor
final class StrengthTypeStore: ObservableObject {
    static let shared = StrengthTypeStore()
    private static let key = "noop.strengthTypes.v1"

    @Published private(set) var types: [StrengthCategory]

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.key)
        types = raw?.compactMap(StrengthCategory.init(rawValue:)) ?? StrengthCategory.builtIn
    }

    func contains(_ c: StrengthCategory?) -> Bool { c.map(types.contains) ?? false }

    /// Add a type by name. A built-in's name ("push", "Legs") brings that built-in back. Returns it, or
    /// nil for an empty name.
    @discardableResult
    func add(_ name: String) -> StrengthCategory? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let c = StrengthCategory.builtIn.first {
            $0.rawValue == clean.lowercased() || $0.displayName.lowercased() == clean.lowercased()
        } ?? types.first { $0.displayName.lowercased() == clean.lowercased() }
            ?? StrengthCategory(rawValue: clean)
        guard let c else { return nil }
        if !types.contains(c) {
            types.append(c)
            save()
        }
        return c
    }

    /// Delete a type: gone from every picker, and from the workouts and exercises it was set on. Sets
    /// that had it count as uncategorised.
    func delete(_ c: StrengthCategory) {
        types.removeAll { $0 == c }
        save()
        WorkoutCategoryStore.shared.forget(c)
        ExerciseCategoryStore.shared.forget(c)
    }

    private func save() { UserDefaults.standard.set(types.map(\.rawValue), forKey: Self.key) }
}

/// Type per exercise, kept on this device by exercise name. An exercise you haven't set gets a default
/// from its name or its primary muscle (`StrengthCategory.guess`), when that type is still in your list;
/// setting one stores it, and every set of that exercise, in any workout, inherits it.
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

    /// The type an exercise counts as: yours if set, else the default; only types in your list.
    func category(for name: String, primaryRegion: String? = nil) -> StrengthCategory? {
        let k = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let types = StrengthTypeStore.shared
        if let raw = stored[k] {
            let c = raw == Self.none ? nil : StrengthCategory(rawValue: raw)
            return types.contains(c) ? c : nil
        }
        let g = StrengthCategory.guess(name: name, primaryRegion: primaryRegion ?? regions[k])
        return types.contains(g) ? g : nil
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
    func isDefault(_ name: String) -> Bool {
        stored[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] == nil
    }

    func set(_ c: StrengthCategory?, for name: String) {
        let k = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return }
        stored[k] = c?.rawValue ?? Self.none
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    /// A deleted type: exercises set to it go back to their default.
    func forget(_ c: StrengthCategory) {
        stored = stored.filter { $0.value != c.rawValue }
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    /// For code that isn't observing: the same answer.
    static func category(for name: String) -> StrengthCategory? { shared.category(for: name) }
}

/// Types for a whole strength workout, kept on this device by the workout's start: what the workout
/// was, any number of them. A set in it with no type of its own or from its exercise takes the
/// workout's when there's just one.
@MainActor
final class WorkoutCategoryStore: ObservableObject {
    static let shared = WorkoutCategoryStore()
    private static let key = "noop.workoutCategories.v1"

    /// Strength sports, by lower-cased name: the ones that count sets.
    static let strengthSports: Set<String> = ["strength", "weightlifting", "bodybuilding", "powerlifting",
                                              "calisthenics", "strength training", "functional fitness"]
    static func isStrength(_ sport: String) -> Bool {
        strengthSports.contains(sport.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Start (unix seconds, as text) → category raw values.
    @Published private(set) var stored: [String: [String]]

    private init() {
        stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    func categories(startTs: Int) -> Set<StrengthCategory> {
        Set((stored[String(startTs)] ?? []).compactMap(StrengthCategory.init(rawValue:))
            .filter(StrengthTypeStore.shared.types.contains))
    }

    /// The one category unassigned sets take: only when the workout is a single one.
    func fallback(startTs: Int) -> StrengthCategory? {
        let c = categories(startTs: startTs)
        return c.count == 1 ? c.first : nil
    }

    func set(_ c: Set<StrengthCategory>, startTs: Int) {
        let raw = StrengthTypeStore.shared.types.filter(c.contains).map(\.rawValue)
        if raw.isEmpty { stored[String(startTs)] = nil } else { stored[String(startTs)] = raw }
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    /// Follow a workout whose start was edited.
    func move(from old: Int, to new: Int) {
        guard old != new, let v = stored[String(old)] else { return }
        stored[String(old)] = nil
        stored[String(new)] = v
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    func forget(_ c: StrengthCategory) {
        stored = stored.compactMapValues { v in
            let left = v.filter { $0 != c.rawValue }
            return left.isEmpty ? nil : left
        }
        UserDefaults.standard.set(stored, forKey: Self.key)
    }
}

extension StrengthCategory {
    var displayName: String {
        switch self {
        case .push: return String(localized: "Push")
        case .pull: return String(localized: "Pull")
        case .legs: return String(localized: "Legs")
        case .abs: return String(localized: "Abs")
        case .accessory: return String(localized: "Accessory")
        default: return rawValue
        }
    }

    var color: Color {
        switch self {
        case .push: return StrandPalette.metricRose
        case .pull: return StrandPalette.accent
        case .legs: return StrandPalette.metricAmber
        case .abs: return StrandPalette.metricCyan
        case .accessory: return StrandPalette.metricPurple
        default:
            // Your own types: a steady colour from the name, so it's the same everywhere.
            let palette = [StrandPalette.statusPositive, StrandPalette.effortColor, StrandPalette.statusWarning,
                           StrandPalette.metricCyan, StrandPalette.metricRose]
            let h = rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return palette[h % palette.count]
        }
    }
}

/// Chips that wrap onto more lines when they don't fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// Your strength types as chips: tap to choose (and tap a chosen one to take it off), + to add a new
/// type, and hold one to delete the type itself. `shaded` marks an inherited choice, lighter.
struct StrengthTypeChips: View {
    var chosen: Set<StrengthCategory>
    var shaded: StrengthCategory? = nil
    /// Worked out rather than chosen: shown lightly.
    var suggested: Set<StrengthCategory> = []
    var small = false
    var onTap: (StrengthCategory) -> Void
    /// A type just added: usually chosen at once.
    var onAdd: ((StrengthCategory) -> Void)? = nil
    @ObservedObject private var types = StrengthTypeStore.shared
    @State private var adding = false
    @State private var newName = ""
    @State private var deleting: StrengthCategory?

    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(types.types, id: \.self) { c in
                let on = chosen.contains(c)
                let light = !on && (shaded == c || suggested.contains(c))
                Button { onTap(c) } label: {
                    HStack(spacing: 4) {
                        Text(c.displayName)
                        if on { Image(systemName: "xmark").font(.system(size: small ? 8 : 9, weight: .bold)) }
                    }
                    .font((small ? StrandFont.caption : StrandFont.footnote).weight(.semibold))
                    .foregroundStyle(on ? Color.white : (light ? c.color : StrandPalette.textSecondary))
                    .padding(.horizontal, small ? 10 : 11)
                    .padding(.vertical, small ? 5 : 7)
                    .background(Capsule().fill(on ? c.color : (light ? c.color.opacity(0.16) : StrandPalette.surfaceInset)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on || light ? [.isSelected] : [])
                .contextMenu {
                    Button(role: .destructive) { deleting = c } label: {
                        Label("Delete type \(c.displayName)", systemImage: "trash")
                    }
                }
            }
            Button { newName = ""; adding = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: small ? 10 : 12, weight: .bold))
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.horizontal, small ? 9 : 11)
                    .padding(.vertical, small ? 6 : 8)
                    .background(Capsule().stroke(StrandPalette.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a type")
        }
        .alert("New type", isPresented: $adding) {
            TextField("Olympic lifts", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { if let c = types.add(newName) { onAdd?(c) } }
        } message: {
            Text("A kind of strength work, like Push or Legs.")
        }
        .confirmationDialog(deleting.map { String(localized: "Delete the type \($0.displayName)?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { types.delete(d) }; deleting = nil }
        } message: {
            Text("It's taken off every workout and exercise that had it. Your sets and workouts stay. You can add it back with +.")
        }
    }
}

/// Types for a whole workout: any number, tap to add or take off.
struct WorkoutCategoryPicker: View {
    @Binding var selection: Set<StrengthCategory>

    var body: some View {
        StrengthTypeChips(chosen: selection,
                          onTap: { c in if selection.contains(c) { selection.remove(c) } else { selection.insert(c) } },
                          onAdd: { c in selection.insert(c) })
    }
}

/// The quick type choice for one exercise: one tap, remembered by name. Tap it again to clear.
struct StrengthCategoryPicker: View {
    let exercise: String
    var primaryRegion: String? = nil
    @ObservedObject private var store = ExerciseCategoryStore.shared
    @ObservedObject private var types = StrengthTypeStore.shared

    var body: some View {
        let current = store.category(for: exercise, primaryRegion: primaryRegion)
        let isDefault = store.isDefault(exercise)
        VStack(alignment: .leading, spacing: 4) {
            StrengthTypeChips(chosen: isDefault ? [] : Set([current].compactMap { $0 }),
                              shaded: isDefault ? current : nil,
                              onTap: { c in store.set(current == c && !isDefault ? nil : c, for: exercise) },
                              onAdd: { c in store.set(c, for: exercise) })
            if current != nil, isDefault {
                Text("Suggested from the name. Tap to keep it or choose another.")
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

/// "Push 3 · Pull 2 · Legs 4" as coloured tags, in your types' order.
struct CategoryCounts: View {
    let counts: [StrengthCategory: Int]
    @ObservedObject private var types = StrengthTypeStore.shared
    var body: some View {
        ChipFlow(spacing: 6) {
            ForEach(types.types.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { c in
                HStack(spacing: 3) {
                    StrengthCategoryTag(category: c)
                    Text("\(counts[c] ?? 0)")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
