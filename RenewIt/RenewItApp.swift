import SwiftData
import SwiftUI

@main
struct RenewItApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            let configuration = ModelConfiguration(cloudKitDatabase: .none)
            modelContainer = try ModelContainer(
                for: Subscription.self,
                configurations: configuration
            )
            Self.migrateLegacyDataIfNeeded(into: modelContainer)
        } catch {
            fatalError("无法创建本地数据库：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        }
        .modelContainer(modelContainer)
    }

    private static func migrateLegacyDataIfNeeded(into container: ModelContainer) {
        let defaults = UserDefaults.standard
        let migrationKey = "didMigrateSubscriptionsToSwiftData"
        let legacyStorageKey = "savedSubscriptions"

        guard !defaults.bool(forKey: migrationKey) else {
            return
        }

        guard let data = defaults.data(forKey: legacyStorageKey) else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        guard let legacySubscriptions = try? JSONDecoder().decode(
            [LegacySubscription].self,
            from: data
        ) else {
            return
        }

        let context = ModelContext(container)

        do {
            let existingSubscriptions = try context.fetch(FetchDescriptor<Subscription>())
            let existingIDs = Set(existingSubscriptions.map(\.id))

            for legacy in legacySubscriptions where !existingIDs.contains(legacy.id) {
                context.insert(
                    Subscription(
                        id: legacy.id,
                        name: legacy.name,
                        expirationDate: legacy.expirationDate,
                        renewalInterval: legacy.renewalInterval,
                        renewalUnit: legacy.renewalUnit,
                        autoRenews: legacy.autoRenews,
                        category: legacy.category ?? .other
                    )
                )
            }

            try context.save()
            defaults.set(true, forKey: migrationKey)
        } catch {
            // Keep the legacy data and retry the migration on the next launch.
        }
    }
}

private struct LegacySubscription: Decodable {
    let id: UUID
    let name: String
    let expirationDate: Date
    let renewalInterval: Int
    let renewalUnit: RenewalUnit
    let autoRenews: Bool
    let category: SubscriptionCategory?
}
