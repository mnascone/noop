import Foundation

/// Daily nutrition totals read from Apple Health (written there by food logs such as MacroFactor),
/// stored as metric series under the apple-health source.
enum NutritionKeys {
    static let kcal = "nutrition_kcal"
    static let protein = "nutrition_protein_g"
    static let carbs = "nutrition_carbs_g"
    static let fat = "nutrition_fat_g"
}

/// How the food log reaches NOOP on this install. The iOS app fills these in from its Apple Health bridge;
/// elsewhere nutrition only arrives through the Shortcut import.
@MainActor
enum NutritionHealthLink {
    enum Status: Equatable {
        /// Apple Health is connected and readable.
        case connected
        /// Apple Health works on this install but hasn't been turned on in NOOP yet.
        case notConnected
        /// Turned off in the Health app.
        case denied
        /// This install was signed without the HealthKit permission (free Apple ID sideloading).
        case noHealthKit
        /// No Apple Health on this device.
        case unavailable
    }

    static var status: () -> Status = { .unavailable }
    /// Ask for Apple Health access, then read the last month.
    static var connect: () async -> Void = {}
    /// Re-read recent days from Apple Health.
    static var refresh: () async -> Void = {}
}
