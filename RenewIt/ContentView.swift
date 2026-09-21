import SwiftData
import SwiftUI
import UserNotifications

@Model
final class Subscription {
    var id: UUID = UUID()
    var name: String = ""
    var expirationDate: Date = Date.now
    var renewalInterval: Int = 1
    var renewalUnitRawValue: String = "year"
    var autoRenews: Bool = false
    var categoryRawValue: String = "other"
    var reminderEnabled: Bool = false
    var reminderDaysBefore: Int = 3

    var renewalUnit: RenewalUnit {
        get { RenewalUnit(rawValue: renewalUnitRawValue) ?? .year }
        set { renewalUnitRawValue = newValue.rawValue }
    }

    var category: SubscriptionCategory {
        get { SubscriptionCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        name: String,
        expirationDate: Date,
        renewalInterval: Int,
        renewalUnit: RenewalUnit,
        autoRenews: Bool,
        category: SubscriptionCategory = .other,
        reminderEnabled: Bool = true,
        reminderDaysBefore: Int = 3
    ) {
        self.id = id
        self.name = name
        self.expirationDate = expirationDate
        self.renewalInterval = renewalInterval
        renewalUnitRawValue = renewalUnit.rawValue
        self.autoRenews = autoRenews
        categoryRawValue = category.rawValue
        self.reminderEnabled = reminderEnabled
        self.reminderDaysBefore = reminderDaysBefore
    }

    var cycleDescription: String {
        if renewalUnit == .month && renewalInterval == 3 {
            return "每季"
        }

        if renewalUnit == .month && renewalInterval == 6 {
            return "每半年"
        }

        if renewalInterval == 1 {
            return "每\(renewalUnit.singleDisplayName)"
        }

        return "每 \(renewalInterval) \(renewalUnit.displayName)"
    }

    func daysRemaining(relativeTo date: Date = .now) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: expirationDate)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

enum RenewalUnit: String, Codable, CaseIterable, Identifiable {
    case week
    case month
    case year

    var id: Self { self }

    var displayName: String {
        switch self {
        case .week:
            "周"
        case .month:
            "个月"
        case .year:
            "年"
        }
    }

    var singleDisplayName: String {
        switch self {
        case .week:
            "周"
        case .month:
            "月"
        case .year:
            "年"
        }
    }
}

enum SubscriptionCategory: String, Codable, CaseIterable, Identifiable {
    case entertainment
    case workAndLife
    case education
    case artificialIntelligence
    case cloudServices
    case healthAndFitness
    case shopping
    case gaming
    case other

    var id: Self { self }

    var displayName: String {
        switch self {
        case .entertainment:
            "影音娱乐"
        case .workAndLife:
            "工作生活"
        case .education:
            "学习教育"
        case .artificialIntelligence:
            "AI 工具"
        case .cloudServices:
            "云服务"
        case .healthAndFitness:
            "健康健身"
        case .shopping:
            "购物会员"
        case .gaming:
            "游戏"
        case .other:
            "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .entertainment:
            "play.tv.fill"
        case .workAndLife:
            "briefcase.fill"
        case .education:
            "graduationcap.fill"
        case .artificialIntelligence:
            "sparkles"
        case .cloudServices:
            "cloud.fill"
        case .healthAndFitness:
            "heart.fill"
        case .shopping:
            "bag.fill"
        case .gaming:
            "gamecontroller.fill"
        case .other:
            "square.grid.2x2.fill"
        }
    }
}

@MainActor
private enum SubscriptionReminderScheduler {
    private static let identifierPrefix = "subscription-reminder-"

    static func update(for subscription: Subscription) {
        let center = UNUserNotificationCenter.current()
        let identifier = identifierPrefix + subscription.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard subscription.reminderEnabled else {
            return
        }

        let calendar = Calendar.current
        let expirationDay = calendar.startOfDay(for: subscription.expirationDate)
        guard
            let reminderDay = calendar.date(
                byAdding: .day,
                value: -subscription.reminderDaysBefore,
                to: expirationDay
            ),
            let reminderDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: reminderDay),
            reminderDate > .now
        else {
            return
        }

        let name = subscription.name
        let expirationText = subscription.expirationDate.formatted(
            .dateTime
                .year()
                .month()
                .day()
                .locale(Locale(identifier: "zh_Hans_CN"))
        )
        let triggerComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminderDate
        )

        Task { @MainActor in
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = "\(name) 即将到期"
                content.body = "会员将在 \(expirationText) 到期，请检查续费设置。"
                content.sound = .default
                content.threadIdentifier = "subscription-reminders"

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: triggerComponents,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                )
                try await center.add(request)
            } catch {
                // Keep the membership record even if notification scheduling fails.
            }
        }
    }

    static func cancel(for subscription: Subscription) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifierPrefix + subscription.id.uuidString]
        )
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Subscription.expirationDate) private var subscriptions: [Subscription]
    @State private var editorRoute: EditorRoute?
    @State private var pendingDeletion: Subscription?
    @State private var selectedCategory: SubscriptionCategory?

    private var sortedSubscriptions: [Subscription] {
        let subscriptions = if let selectedCategory {
            subscriptions.filter { $0.category == selectedCategory }
        } else {
            subscriptions
        }
        return subscriptions.sorted { $0.expirationDate < $1.expirationDate }
    }

    private var categoryGroups: [SubscriptionCategoryGroup] {
        let grouped = Dictionary(grouping: sortedSubscriptions, by: \.category)
        return SubscriptionCategory.allCases.compactMap { category in
            guard let subscriptions = grouped[category] else {
                return nil
            }
            return SubscriptionCategoryGroup(
                category: category,
                subscriptions: subscriptions
            )
        }
    }

    private var expiringSoonCount: Int {
        subscriptions.filter {
            let remaining = $0.daysRemaining()
            return remaining >= 0 && remaining <= 30
        }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if subscriptions.isEmpty {
                    emptyState
                } else if sortedSubscriptions.isEmpty {
                    ContentUnavailableView(
                        "这个分类还没有会员",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("可以选择其他分类，或添加一条新记录。")
                    )
                } else {
                    subscriptionList
                }
            }
            .navigationTitle("我的会员")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    categoryFilterMenu

                    Button {
                        editorRoute = .new
                    } label: {
                        Label("添加会员", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorRoute) { route in
                SubscriptionEditor(
                    subscription: route.subscription,
                    onSave: { subscription in
                        save(subscription, replacing: route.subscription)
                    },
                    onDelete: route.subscription.map { subscription in
                        { delete(subscription) }
                    }
                )
            }
            .alert(
                "确定删除这个会员吗？",
                item: $pendingDeletion
            ) { subscription in
                Button("删除", role: .destructive) {
                    delete(subscription)
                }
                Button("取消", role: .cancel) {}
            } message: { subscription in
                Text("“\(subscription.name)”将被永久删除，此操作无法撤销。")
            }
        }
    }

    private var categoryFilterMenu: some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                Label("全部分类", systemImage: selectedCategory == nil ? "checkmark" : "square.grid.2x2")
            }

            ForEach(SubscriptionCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    Label(
                        category.displayName,
                        systemImage: selectedCategory == category ? "checkmark" : category.systemImage
                    )
                }
            }
        } label: {
            Label(
                selectedCategory?.displayName ?? "筛选分类",
                systemImage: selectedCategory == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有会员记录", systemImage: "calendar.badge.clock")
        } description: {
            Text("添加互联网应用会员，集中管理到期日和续费方式。")
        } actions: {
            Button("添加第一个会员") {
                editorRoute = .new
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var subscriptionList: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    SummaryItem(
                        value: "\(subscriptions.count)",
                        title: "全部会员",
                        systemImage: "square.grid.2x2"
                    )
                    Divider()
                    SummaryItem(
                        value: "\(expiringSoonCount)",
                        title: "30 天内到期",
                        systemImage: "clock.badge.exclamationmark"
                    )
                }
                .padding(.vertical, 8)
            }

            ForEach(categoryGroups) { group in
                Section {
                    ForEach(group.subscriptions) { subscription in
                        Button {
                            editorRoute = .edit(subscription)
                        } label: {
                            SubscriptionRow(subscription: subscription)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("删除") {
                                pendingDeletion = subscription
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    Label(
                        group.category.displayName,
                        systemImage: group.category.systemImage
                    )
                }
            }
        }
    }

    private func save(_ subscription: Subscription, replacing existing: Subscription?) {
        let savedSubscription: Subscription

        if let existing {
            existing.name = subscription.name
            existing.expirationDate = subscription.expirationDate
            existing.renewalInterval = subscription.renewalInterval
            existing.renewalUnit = subscription.renewalUnit
            existing.autoRenews = subscription.autoRenews
            existing.category = subscription.category
            existing.reminderEnabled = subscription.reminderEnabled
            existing.reminderDaysBefore = subscription.reminderDaysBefore
            savedSubscription = existing
        } else {
            modelContext.insert(subscription)
            savedSubscription = subscription
        }

        try? modelContext.save()
        SubscriptionReminderScheduler.update(for: savedSubscription)
    }

    private func delete(_ subscription: Subscription) {
        SubscriptionReminderScheduler.cancel(for: subscription)
        modelContext.delete(subscription)
        try? modelContext.save()
    }
}

private struct SubscriptionCategoryGroup: Identifiable {
    let category: SubscriptionCategory
    let subscriptions: [Subscription]

    var id: SubscriptionCategory { category }
}

private struct SummaryItem: View {
    let value: String
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SubscriptionRow: View {
    let subscription: Subscription

    private var remainingText: String {
        let days = subscription.daysRemaining()
        switch days {
        case ..<0:
            return "已到期 \(-days) 天"
        case 0:
            return "今天到期"
        default:
            return "还有 \(days) 天"
        }
    }

    private var urgencyColor: Color {
        let days = subscription.daysRemaining()
        if days < 0 {
            return .red
        }
        if days <= 7 {
            return .orange
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: subscription.category.systemImage)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.tint, in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                Text(subscription.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(subscription.cycleDescription)
                    Image(
                        systemName: subscription.autoRenews
                            ? "arrow.trianglehead.2.clockwise.rotate.90"
                            : "hand.tap"
                    )
                    .accessibilityLabel(subscription.autoRenews ? "自动续费" : "手动续费")

                    if subscription.reminderEnabled {
                        Image(systemName: "bell.fill")
                            .accessibilityLabel("提前 \(subscription.reminderDaysBefore) 天提醒")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(
                    subscription.expirationDate,
                    format: .dateTime.year().month(.abbreviated).day()
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

                Text(remainingText)
                    .font(.caption)
                    .foregroundStyle(urgencyColor)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("轻点编辑会员")
    }
}

private enum EditorRoute: Identifiable {
    case new
    case edit(Subscription)

    var id: String {
        switch self {
        case .new:
            "new"
        case .edit(let subscription):
            subscription.id.uuidString
        }
    }

    var subscription: Subscription? {
        switch self {
        case .new:
            nil
        case .edit(let subscription):
            subscription
        }
    }
}

private struct SubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss

    let originalSubscription: Subscription?
    let onSave: (Subscription) -> Void
    let onDelete: (() -> Void)?

    @State private var name: String
    @State private var expirationDate: Date
    @State private var renewalInterval: Int
    @State private var renewalUnit: RenewalUnit
    @State private var autoRenews: Bool
    @State private var category: SubscriptionCategory
    @State private var reminderEnabled: Bool
    @State private var reminderDaysBefore: Int
    @State private var showsDeleteConfirmation = false

    init(
        subscription: Subscription?,
        onSave: @escaping (Subscription) -> Void,
        onDelete: (() -> Void)?
    ) {
        originalSubscription = subscription
        self.onSave = onSave
        self.onDelete = onDelete

        _name = State(initialValue: subscription?.name ?? "")
        _expirationDate = State(initialValue: subscription?.expirationDate ?? .now)
        _renewalInterval = State(initialValue: subscription?.renewalInterval ?? 1)
        _renewalUnit = State(initialValue: subscription?.renewalUnit ?? .year)
        _autoRenews = State(initialValue: subscription?.autoRenews ?? true)
        _category = State(initialValue: subscription?.category ?? .other)
        _reminderEnabled = State(initialValue: subscription?.reminderEnabled ?? true)
        _reminderDaysBefore = State(initialValue: subscription?.reminderDaysBefore ?? 3)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("应用") {
                    TextField("例如：Netflix", text: $name)
                        .textInputAutocapitalization(.words)

                    Picker("分类", selection: $category) {
                        ForEach(SubscriptionCategory.allCases) { category in
                            Label(category.displayName, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                }

                Section("有效期") {
                    DatePicker(
                        "到期日",
                        selection: $expirationDate,
                        displayedComponents: .date
                    )
                }

                Section {
                    Toggle("启用提醒", isOn: $reminderEnabled)

                    if reminderEnabled {
                        Stepper(value: $reminderDaysBefore, in: 0...30) {
                            LabeledContent("提醒时间", value: reminderTimingText)
                        }
                    }
                } header: {
                    Text("到期提醒")
                } footer: {
                    if reminderEnabled {
                        Text("提醒将在所选日期上午 9:00 发送。")
                    }
                }

                Section("续费设置") {
                    Toggle("自动续费", isOn: $autoRenews)

                    Stepper(value: $renewalInterval, in: 1...24) {
                        LabeledContent("间隔", value: "\(renewalInterval)")
                    }

                    Picker("周期单位", selection: $renewalUnit) {
                        ForEach(RenewalUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }

                    LabeledContent("当前周期", value: cyclePreview)
                }

                if onDelete != nil {
                    Section {
                        Button("删除会员", role: .destructive) {
                            showsDeleteConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle(originalSubscription == nil ? "添加会员" : "编辑会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .alert(
                "确定删除这个会员吗？",
                isPresented: $showsDeleteConfirmation
            ) {
                Button("删除", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
            } message: {
                Text("此操作无法撤销。")
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var reminderTimingText: String {
        if reminderDaysBefore == 0 {
            return "到期当天"
        }
        return "提前 \(reminderDaysBefore) 天"
    }

    private var cyclePreview: String {
        Subscription(
            name: "",
            expirationDate: expirationDate,
            renewalInterval: renewalInterval,
            renewalUnit: renewalUnit,
            autoRenews: autoRenews,
            category: category
        ).cycleDescription
    }

    private func save() {
        let subscription = Subscription(
            id: originalSubscription?.id ?? UUID(),
            name: trimmedName,
            expirationDate: expirationDate,
            renewalInterval: renewalInterval,
            renewalUnit: renewalUnit,
            autoRenews: autoRenews,
            category: category,
            reminderEnabled: reminderEnabled,
            reminderDaysBefore: reminderDaysBefore
        )
        onSave(subscription)
        dismiss()
    }
}

#Preview {
    ContentView()
}
