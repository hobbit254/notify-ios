import SwiftUI

/// The drop-in notification center (docs/UI.md § Mobile SDK): filter pills, Today / Earlier sections,
/// swipe to read or archive, an "Open" pill for items with a URL, and a sync banner.
/// Embed it in a NavigationStack; pass `accent` to theme it (docs/UI.md accent by default).
public struct NotificationCenterView: View {
    @ObservedObject private var notify: Notify
    private let title: String
    private let highlightCategory: String
    private let onPreferences: (() -> Void)?
    private let accent: Color
    @State private var filter: Filter = .all
    @Environment(\.openURL) private var openURL

    enum Filter: Hashable { case all, unread, category }

    /// - highlightCategory: the third pill filters to this payload category ("mentions" by default).
    /// - onPreferences: shows a preferences button in the toolbar.
    public init(_ notify: Notify, title: String = "Notifications", highlightCategory: String = "mentions",
                accent: Color = Token.accent, onPreferences: (() -> Void)? = nil) {
        self.accent = accent
        self.notify = notify
        self.title = title
        self.highlightCategory = highlightCategory
        self.onPreferences = onPreferences
    }

    private var visible: [InboxItem] {
        notify.items.filter { item in
            guard item.state != .archived else { return false }
            switch filter {
            case .all: return true
            case .unread: return item.state == .unread
            case .category: return item.payload.category == highlightCategory
            }
        }
    }

    public var body: some View {
        let today = visible.filter { Calendar.current.isDateInToday($0.date) }
        let earlier = visible.filter { !Calendar.current.isDateInToday($0.date) }
        VStack(spacing: 0) {
            pills
            List {
                if visible.isEmpty {
                    Text(filter == .unread ? "No unread notifications." : "You're all caught up.")
                        .font(.system(size: 13)).foregroundStyle(Token.muted)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 48)
                        .listRowSeparator(.hidden)
                }
                if !today.isEmpty { section("Today", today) }
                if !earlier.isEmpty { section("Earlier", earlier) }
            }
            .listStyle(.plain)
            banner
        }
        .navigationTitle(title)
        .toolbar {
            if let onPreferences {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onPreferences) { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Notification preferences")
                }
            }
        }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            pill("All", .all)
            pill("Unread · \(notify.unread)", .unread)
            pill(highlightCategory.capitalized, .category)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func pill(_ label: String, _ f: Filter) -> some View {
        Button { filter = f } label: {
            Text(label).font(.system(size: 13, weight: filter == f ? .semibold : .regular))
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Capsule().fill(filter == f ? Token.accentTint : Token.canvas))
                .foregroundStyle(filter == f ? accent : Token.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == f ? .isSelected : [])
    }

    private func section(_ name: String, _ items: [InboxItem]) -> some View {
        Section {
            ForEach(items) { item in
                row(item)
                    .listRowBackground(item.state == .unread ? Token.unreadTint : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await notify.markRead(item.id) } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { Task { await notify.archive(item.id) } } label: { Label("Archive", systemImage: "archivebox") }
                            .tint(Token.danger)
                        if item.state == .unread {
                            Button { Task { await notify.markRead(item.id) } } label: { Label("Read", systemImage: "envelope.open") }
                                .tint(.gray)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(label(item))
                    .accessibilityAction(named: "Mark read") { Task { await notify.markRead(item.id) } }
                    .accessibilityAction(named: "Archive") { Task { await notify.archive(item.id) } }
            }
        } header: {
            Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Token.muted)
        }
    }

    private func label(_ item: InboxItem) -> String {
        [item.state == .unread ? "Unread" : nil, item.payload.title ?? item.template, item.payload.body,
         item.date.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: ", ")
    }

    private func row(_ item: InboxItem) -> some View {
        let p = item.payload
        let title = p.title ?? item.template ?? "Notification"
        return HStack(alignment: .top, spacing: 12) {
            Text(String((p.category ?? title).prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 40, height: 40).background(Circle().fill(Token.accentTint))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Token.ink)
                if let body = p.body {
                    Text(body).font(.system(size: 13)).foregroundStyle(Token.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let c = p.category {
                        Text(c).font(.system(size: 11.5)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(Capsule().fill(Token.canvas)).foregroundStyle(Token.secondary)
                    }
                    Text(item.date, format: .relative(presentation: .named)).font(.system(size: 11.5)).foregroundStyle(Token.muted)
                }
                if let s = p.url, let url = URL(string: s) {
                    Button {
                        Task { await notify.markRead(item.id) }
                        openURL(url)
                    } label: {
                        Text("Open").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).frame(minHeight: 36)
                            .background(Capsule().fill(accent)).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            if item.state == .unread {
                Circle().fill(accent).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
    }

    private var banner: some View {
        let text: String = switch notify.status {
        case .online: "Synced just now · \(notify.unread) unread"
        case .connecting: "Connecting…"
        case .offline: "Offline · showing saved notifications"
        case .idle: "Not connected"
        }
        return Text(text).font(.system(size: 11.5))
            .foregroundStyle(notify.status == .online ? Token.success : notify.status == .offline ? Token.warning : Token.muted)
            .frame(maxWidth: .infinity).padding(.vertical, 10).background(Token.canvas)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// docs/UI.md design tokens.
public enum Token {
    public static let accent = Color(hex: 0x1F4FD8)
    public static let ink = Color(hex: 0x17191F)
    public static let secondary = Color(hex: 0x4B5361)
    public static let muted = Color(hex: 0x6B7280)
    public static let canvas = Color(hex: 0xF5F6F8)
    public static let accentTint = Color(hex: 0xEEF2FF)
    public static let unreadTint = Color(hex: 0xF5F7FF)
    public static let success = Color(hex: 0x15803D)
    public static let warning = Color(hex: 0xB45309)
    public static let danger = Color(hex: 0xB91C1C)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
