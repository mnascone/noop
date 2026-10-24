import Foundation

/// Daily nutrition totals read from Apple Health (written there by food logs such as MacroFactor),
/// stored as metric series under the apple-health source.
enum NutritionKeys {
    static let kcal = "nutrition_kcal"
    static let protein = "nutrition_protein_g"
    static let carbs = "nutrition_carbs_g"
    static let fat = "nutrition_fat_g"
}
