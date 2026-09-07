import SwiftUI

struct Subscription: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var expirationDate: Date
    var renewalInterval: Int
    var renewalUnit: RenewalUnit
    var autoRenews: Bool

    init(
        id: UUID = UUID(),
        name: String,
        expirationDate: Date,
        renewalInterval: Int,
        renewalUnit: RenewalUnit,
        autoRenews: Bool
    ) {
        self.id = id
        self.name = name
        self.expirationDate = expirationDate
        self.renewalInterval = renewalInterval
        self.renewalUnit = renewalUnit
        self.autoRenews = autoRenews
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

@MainActor
@Observable
final class SubscriptionStore {
    private static let storageKey = "savedSubscriptions"

    var subscriptions: [Subscription] = [] {
        didSet {
            save()
        }
    }

    init() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
        else {
            return
        }

        subscriptions = decoded
    }

    func add(_ subscription: Subscription) {
        subscriptions.append(subscription)
    }

    func update(_ subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else {
            return
        }
        subscriptions[index] = subscription
    }

    func delete(id: UUID) {
        subscriptions.removeAll { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(subscriptions) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

struct ContentView: View {
    @State private var store = SubscriptionStore()
    @State private var editorRoute: EditorRoute?

    private var sortedSubscriptions: [Subscription] {
        store.subscriptions.sorted { $0.expirationDate < $1.expirationDate }
    }

    private var expiringSoonCount: Int {
        store.subscriptions.filter {
            let remaining = $0.daysRemaining()
            return remaining >= 0 && remaining <= 30
        }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedSubscriptions.isEmpty {
                    emptyState
                } else {
                    subscriptionList
                }
            }
            .navigationTitle("我的会员")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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
                        if route.subscription == nil {
                            store.add(subscription)
                        } else {
                            store.update(subscription)
                        }
                    },
                    onDelete: route.subscription.map { subscription in
                        { store.delete(id: subscription.id) }
                    }
                )
            }
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
                        value: "\(store.subscriptions.count)",
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

            Section("按到期日") {
                ForEach(sortedSubscriptions) { subscription in
                    Button {
                        editorRoute = .edit(subscription)
                    } label: {
                        SubscriptionRow(subscription: subscription)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            store.delete(id: subscription.id)
                        }
                    }
                }
            }
        }
    }
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
            return "已到期"
        case 0:
            return "今天到期"
        case 1...30:
            return "还有 \(days) 天"
        default:
            return subscription.expirationDate.formatted(date: .abbreviated, time: .omitted)
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
            Image(systemName: "app.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.tint.gradient, in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                Text(subscription.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(subscription.cycleDescription)
                    Text("·")
                    Label(
                        subscription.autoRenews ? "自动续费" : "手动续费",
                        systemImage: subscription.autoRenews ? "arrow.trianglehead.2.clockwise.rotate.90" : "hand.tap"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(remainingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(urgencyColor)
                Text(subscription.expirationDate, format: .dateTime.year().month().day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    var id: UUID {
        switch self {
        case .new:
            UUID()
        case .edit(let subscription):
            subscription.id
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
        _renewalUnit = State(initialValue: subscription?.renewalUnit ?? .month)
        _autoRenews = State(initialValue: subscription?.autoRenews ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("应用") {
                    TextField("例如：Netflix", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("有效期") {
                    DatePicker(
                        "到期日",
                        selection: $expirationDate,
                        displayedComponents: .date
                    )
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
            .confirmationDialog(
                "确定删除这个会员吗？",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
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

    private var cyclePreview: String {
        Subscription(
            name: "",
            expirationDate: expirationDate,
            renewalInterval: renewalInterval,
            renewalUnit: renewalUnit,
            autoRenews: autoRenews
        ).cycleDescription
    }

    private func save() {
        let subscription = Subscription(
            id: originalSubscription?.id ?? UUID(),
            name: trimmedName,
            expirationDate: expirationDate,
            renewalInterval: renewalInterval,
            renewalUnit: renewalUnit,
            autoRenews: autoRenews
        )
        onSave(subscription)
        dismiss()
    }
}

#Preview("有会员") {
    let store = SubscriptionStore()
    store.subscriptions = [
        Subscription(
            name: "Netflix",
            expirationDate: .now.addingTimeInterval(8 * 86_400),
            renewalInterval: 1,
            renewalUnit: .month,
            autoRenews: true
        ),
        Subscription(
            name: "ChatGPT Plus",
            expirationDate: .now.addingTimeInterval(45 * 86_400),
            renewalInterval: 1,
            renewalUnit: .month,
            autoRenews: false
        )
    ]
    return ContentView()
}

#Preview("空状态") {
    ContentView()
}
