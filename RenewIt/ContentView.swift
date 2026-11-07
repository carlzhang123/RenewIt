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

private extension Subscription {
    var expiresWithinThirtyDays: Bool {
        let days = daysRemaining()
        return (0...30).contains(days)
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
    @State private var showsExpiringSoon = false

    private var sortedSubscriptions: [Subscription] {
        let subscriptions = if let selectedCategory {
            subscriptions.filter { $0.category == selectedCategory }
        } else {
            subscriptions
        }
        return subscriptions
            .filter { !showsExpiringSoon || $0.expiresWithinThirtyDays }
            .sorted { $0.expirationDate < $1.expirationDate }
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
        subscriptions.filter(\.expiresWithinThirtyDays).count
    }

    var body: some View {
        NavigationStack {
            Group {
                if subscriptions.isEmpty {
                    emptyState

                } else {
                    subscriptionList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MembershipBackground())
            .tint(.teal)
            .navigationTitle("会员卡包")
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
        ScrollView {
            VStack(spacing: 32) {
                MembershipOverview(total: 0, expiring: 0, showsExpiringSoon: showsExpiringSoon,
                    onShowAll: {
                        showsExpiringSoon = false
                        selectedCategory = nil
                    },
                    onShowExpiring: {
                        showsExpiringSoon = true
                        selectedCategory = nil
                    })
                ContentUnavailableView {
                    Label("美好生活，从有序开始", systemImage: "calendar.badge.clock")
                } description: {
                    Text("添加你的第一个会员，\n让每一次续费都有准备。")
                } actions: {
                    Button("添加第一个会员", systemImage: "plus") {
                        editorRoute = .new
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding(20)
        }
    }

    private var subscriptionList: some View {
        List {
            Section {
                MembershipOverview(
                    total: subscriptions.count,
                    expiring: expiringSoonCount,
                    showsExpiringSoon: showsExpiringSoon,
                    onShowAll: {
                        showsExpiringSoon = false
                        selectedCategory = nil
                    },
                    onShowExpiring: {
                        showsExpiringSoon = true
                        selectedCategory = nil
                    }
                )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if showsExpiringSoon || selectedCategory != nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(showsExpiringSoon ? "正在查看：30 天内到期" : "正在查看：分类筛选")
                            .font(.subheadline.weight(.semibold))
                        Button("查看全部", systemImage: "arrow.uturn.backward") {
                            showsExpiringSoon = false
                            selectedCategory = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if sortedSubscriptions.isEmpty {
                ContentUnavailableView(
                    showsExpiringSoon ? "暂无 30 天内到期的会员" : "这个分类还没有会员",
                    systemImage: "calendar.badge.checkmark",
                    description: Text("可以查看全部会员，或选择其他分类。")
                )
                .listRowBackground(Color.clear)
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
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("删除") {
                                pendingDeletion = subscription
                            }
                            .tint(.red)
                        }
                    }
                } header: {
                    HStack {
                        Label(group.category.displayName, systemImage: group.category.systemImage)
                            .foregroundStyle(group.category.accentColor)
                        Spacer()
                        Text("\(group.subscriptions.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollContentBackground(.hidden)
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

private struct MembershipBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.teal.opacity(0.09), Color.primary.opacity(0.025)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private extension SubscriptionCategory {
    var accentColor: Color {
        switch self {
        case .entertainment: .purple
        case .workAndLife: .blue
        case .education: .indigo
        case .artificialIntelligence: .teal
        case .cloudServices: .cyan
        case .healthAndFitness: .pink
        case .shopping: .orange
        case .gaming: .green
        case .other: .gray
        }
    }
}

private struct MembershipOverview: View {
    let total: Int
    let expiring: Int
    let showsExpiringSoon: Bool
    let onShowAll: () -> Void
    let onShowExpiring: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("RENEW IT", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                Spacer()
                Image(systemName: "sparkle")
                    .font(.title2)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 24) {
                Button(action: onShowAll) {
                    SummaryItem(value: total, title: "全部会员")
                        .padding(10)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("清除筛选，查看全部会员")
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1, height: 50)
                    .accessibilityHidden(true)
                Button(action: onShowExpiring) {
                    SummaryItem(value: expiring, title: "30 天内到期")
                        .padding(10)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showsExpiringSoon ? .isSelected : [])
                .accessibilityHint("筛选从今天起 30 天内到期的会员")
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.29, blue: 0.29),
                         Color(red: 0.08, green: 0.43, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .stroke(.white.opacity(0.07), lineWidth: 34)
                    .frame(width: 180, height: 180)
                    .offset(x: 65, y: -60)
            }
        }
        .clipShape(.rect(cornerRadius: 28))
    }
}

private struct SummaryItem: View {
    let value: Int
    let title: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value, format: .number)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: subscription.category.systemImage)
                    .font(.title2)
                    .foregroundStyle(subscription.category.accentColor)
                    .frame(width: 48, height: 48)
                    .background(subscription.category.accentColor.opacity(0.12), in: .rect(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(subscription.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subscription.cycleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(subscription.autoRenews ? "下次自动续费" : "会员有效期至")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(subscription.expirationDate, format: .dateTime.year().month().day())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(remainingText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(urgencyColor)
                    if subscription.reminderEnabled {
                        Label("已开启提醒", systemImage: "bell")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 24))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                .fill(subscription.category.accentColor.opacity(0.55))
                .frame(width: 36, height: 3)
                .accessibilityHidden(true)
        }
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


private struct MembershipIdentityCard: View {
    @Binding var name: String
    let category: SubscriptionCategory
    let expirationDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                Image(systemName: category.systemImage)
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.15), in: .rect(cornerRadius: 16))
                Spacer()
                Text("RENEW IT / MEMBER")
                    .font(.caption2.weight(.bold))
                    .tracking(2)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("会员名称").font(.caption).foregroundStyle(.white.opacity(0.75))
                TextField("", text: $name, prompt: Text("例如 Netflix").foregroundStyle(.white.opacity(0.55)))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("会员名称")
                    .tint(.white)
            }
            HStack {
                Text(category.displayName)
                Spacer()
                Text(expirationDate, format: .dateTime.year().month().day())
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.25, blue: 0.25), Color(red: 0.12, green: 0.43, blue: 0.38)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 28)
        )
    }
}

private struct EditorSectionTitle: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(.headline)
    }
}

private struct SelectionChip: View {
    let title: String
    let symbol: String
    let selected: Bool
    var color: Color = .teal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 46)
                .padding(.horizontal, 8)
                .foregroundStyle(selected ? color : .primary)
                .background(selected ? color.opacity(0.12) : Color.primary.opacity(0.035),
                            in: .rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(selected ? color.opacity(0.45) : .clear)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CategoryChoices: View {
    @Binding var selection: SubscriptionCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSectionTitle(title: "分类")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 10) {
                ForEach(SubscriptionCategory.allCases) { category in
                    SelectionChip(title: category.displayName, symbol: category.systemImage,
                                  selected: selection == category, color: category.accentColor) {
                        selection = category
                    }
                }
            }
        }
    }
}

private struct ExpirationSection: View {
    @Binding var date: Date
    @State private var showsCalendar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSectionTitle(title: "到期时间")
            Button {
                showsCalendar.toggle()
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "calendar")
                        .font(.title)
                        .foregroundStyle(.teal)
                    Text(date, format: .dateTime.year().month().day())
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: showsCalendar ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.primary)
                .padding(20)
                .background(.background, in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("到期日期")
            .accessibilityValue(date.formatted(date: .abbreviated, time: .omitted))
            if showsCalendar {
                DatePicker("到期日期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(8)
                    .background(.background, in: .rect(cornerRadius: 20))
            }
        }
    }
}

private struct RenewalChoices: View {
    @Binding var interval: Int
    @Binding var unit: RenewalUnit
    @Binding var autoRenews: Bool
    @State private var showsCustom = false

    private var isStandard: Bool {
        interval == 1 && (unit == .month || unit == .year) || interval == 3 && unit == .month
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorSectionTitle(title: "续费周期")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 10) {
                SelectionChip(title: "每月", symbol: "calendar", selected: interval == 1 && unit == .month) {
                    interval = 1; unit = .month; showsCustom = false
                }
                SelectionChip(title: "每季", symbol: "calendar", selected: interval == 3 && unit == .month) {
                    interval = 3; unit = .month; showsCustom = false
                }
                SelectionChip(title: "每年", symbol: "calendar", selected: interval == 1 && unit == .year) {
                    interval = 1; unit = .year; showsCustom = false
                }
                SelectionChip(title: "自定义", symbol: "slider.horizontal.3", selected: showsCustom || !isStandard) {
                    showsCustom.toggle()
                }
            }
            if showsCustom || !isStandard {
                VStack(spacing: 12) {
                    Stepper("每 \(interval) \(unit.displayName)", value: $interval, in: 1...24)
                    Picker("周期单位", selection: $unit) {
                        ForEach(RenewalUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(16)
                .background(.background, in: .rect(cornerRadius: 18))
            }
            Toggle(isOn: $autoRenews) {
                Label("自动续费", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.subheadline)
            }
            .padding(.top, 4)
        }
    }
}

private struct ReminderOptions: View {
    @Binding var enabled: Bool
    @Binding var days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $enabled) {
                Label("到期提醒", systemImage: "bell.badge")
                    .font(.headline)
            }
            if enabled {
                Stepper(days == 0 ? "到期当天" : "提前 \(days) 天", value: $days, in: 0...30)
                    .font(.subheadline)
                Text("提醒将在当天上午 9:00 发送")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.teal.opacity(0.06), in: .rect(cornerRadius: 20))
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
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    MembershipIdentityCard(name: $name, category: category, expirationDate: expirationDate)
                    CategoryChoices(selection: $category)
                    ExpirationSection(date: $expirationDate)
                    RenewalChoices(interval: $renewalInterval, unit: $renewalUnit, autoRenews: $autoRenews)
                    ReminderOptions(enabled: $reminderEnabled, days: $reminderDaysBefore)
                    if onDelete != nil {
                        Button("删除会员", role: .destructive) {
                            showsDeleteConfirmation = true
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(MembershipBackground())
            .tint(.teal)
            .navigationTitle(originalSubscription == nil ? "新会员" : "编辑会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    HStack {
                        Text(originalSubscription == nil ? "添加会员" : "保存修改")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(trimmedName.isEmpty ? Color.gray : Color(red: 0.06, green: 0.34, blue: 0.32),
                                in: .rect(cornerRadius: 20))
                }
                .disabled(trimmedName.isEmpty)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
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
        .modelContainer(for: Subscription.self, inMemory: true)
}

#Preview("新建会员") {
    SubscriptionEditor(subscription: nil, onSave: { _ in }, onDelete: nil)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
}

#Preview("会员卡包") {
    let container = makePreviewContainer()
    let _ = container.mainContext.insert(Subscription(
        name: "Netflix", expirationDate: .now.addingTimeInterval(86400 * 12),
        renewalInterval: 1, renewalUnit: .month, autoRenews: true, category: .entertainment
    ))
    let _ = container.mainContext.insert(Subscription(
        name: "iCloud+", expirationDate: .now.addingTimeInterval(86400 * 60),
        renewalInterval: 1, renewalUnit: .year, autoRenews: true, category: .cloudServices
    ))
    ContentView()
        .modelContainer(container)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
}

@MainActor
private func makePreviewContainer() -> ModelContainer {
    do {
        return try ModelContainer(
            for: Subscription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    } catch {
        fatalError("无法创建预览数据库：\(error)")
    }
}
