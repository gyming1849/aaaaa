import SwiftUI

// MARK: - QuickFoods card `常用食物（一键添加 1 份）` (web1 §5.2, meals §3 step 1)
// The first 12 of `GET /foods?scope=all` (loaded by LogMealModel; hidden when empty), shown only in the input phase
// with no items. A chip `{name} · {serving_g}g` calls `POST /foods/{id}/item {grams: serving_g ?? 100}`.

struct QuickFoodsCard: View {
    @Environment(AppState.self) private var app
    let foods: [Food]
    let onPick: @MainActor (DraftItem) -> Void
    @State private var addingId: Int?

    init(foods: [Food], onPick: @escaping @MainActor (DraftItem) -> Void) {
        self.foods = foods
        self.onPick = onPick
    }

    var body: some View {
        Card {
            CardHeader("常用食物（一键添加 1 份）").headingLevel(.h3)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(foods) { food in
                    Button {
                        Task { await add(food) }
                    } label: {
                        HStack(spacing: 6) {
                            if addingId == food.id {
                                Spinner(size: 12, lineWidth: 1.5)
                            }
                            Chip(Self.label(food))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(addingId != nil)
                }
            }
        }
    }

    /// `{name}{serving_g ? " · {fmt(serving_g)}g" : ""}`.
    static func label(_ food: Food) -> String {
        guard let serving = food.serving_g, serving != 0 else { return food.name }
        return "\(food.name) · \(fmt(serving))g"
    }

    private func add(_ food: Food) async {
        guard addingId == nil else { return }
        addingId = food.id
        defer { addingId = nil }
        do {
            let item = try await app.api.foodItem(id: food.id, grams: food.serving_g ?? 100)
            onPick(item)
        } catch {
            app.toasts.error(error)
        }
    }
}
