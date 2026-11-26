import SwiftUI

/// The drop-in notification center (docs/UI.md § Mobile SDK): filter pills, Today / Earlier sections,
/// swipe to read or archive, an "Open" pill for items with a URL, and a sync banner.
/// Embed it in a NavigationStack. Pulse, dark inside any host app (docs/UI.md § 2; `Token`); `accent` replaces the signal colour.
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
                accent: Color = Token.signal, onPreferences: (() -> Void)? = nil) {
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
                        .font(.system(size: 13)).foregroundStyle(Token.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 48)
                        .listRowSeparator(.hidden).listRowBackground(Token.surface)
                }
                if !today.isEmpty { section("Today", today) }
                if !earlier.isEmpty { section("Earlier", earlier) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            banner
        }
        .background(Token.surface)
        .environment(\.colorScheme, .dark) // system parts (swipe buttons, headers) drawn for the dark surface
        .navigationTitle(title)
        .pulseNavigationBar()
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
            Text(label).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(Capsule().fill(filter == f ? accent : Token.raised))
                .foregroundStyle(filter == f ? Token.onSignal : Token.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == f ? .isSelected : [])
    }

    private func section(_ name: String, _ items: [InboxItem]) -> some View {
        Section {
            ForEach(items) { item in
                row(item)
                    .listRowBackground(item.state == .unread ? Token.raised : Token.surface)
                    .listRowSeparatorTint(Token.border)
                    .onAppear { // infinite scroll: the last row coming into view loads the next page (inbox cursor)
                        if item.id == visible.last?.id, notify.hasOlder { Task { try? await notify.loadOlder() } }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await notify.markRead(item.id) } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { Task { await notify.archive(item.id) } } label: {
                            Label("Archive", systemImage: "archivebox").foregroundStyle(Token.onUnread)
                        }
                        .tint(Token.unread)
                        if item.state == .unread {
                            Button { Task { await notify.markRead(item.id) } } label: { Label("Read", systemImage: "envelope.open") }
                                .tint(Token.borderStrong)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(label(item))
                    .accessibilityAction(named: "Mark read") { Task { await notify.markRead(item.id) } }
                    .accessibilityAction(named: "Archive") { Task { await notify.archive(item.id) } }
            }
        } header: {
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Token.textMuted)
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
                .font(.system(size: 15, weight: .bold)).foregroundStyle(accent)
                .frame(width: 36, height: 36).background(Circle().fill(Token.signalTint))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Token.text)
                if let body = p.body {
                    Text(body).font(.system(size: 13)).foregroundStyle(Token.textSecondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let c = p.category {
                        Text(c).font(.system(size: 11, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Token.signalTint)).foregroundStyle(accent)
                    }
                    Text(item.date, format: .relative(presentation: .named)).font(.system(size: 12)).foregroundStyle(Token.textMuted)
                }
                if let s = p.url, let url = URL(string: s) {
                    Button {
                        Task { await notify.markRead(item.id) }
                        openURL(url)
                    } label: {
                        Text("Open").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).frame(minHeight: 36)
                            .background(Capsule().fill(accent)).foregroundStyle(Token.onSignal)
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            if item.state == .unread {
                Circle().fill(Token.unread).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
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
        return Text(text).font(.system(size: 12))
            .foregroundStyle(notify.status == .online ? Token.success : notify.status == .offline ? Token.warning : Token.textMuted)
            .frame(maxWidth: .infinity).padding(.vertical, 10).background(Token.raised)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Pulse, the components' palette (docs/UI.md § Pulse tokens; the web SDK's packages/react/src/theme.ts has the
/// same values). Where the brand spec failed WCAG it was changed, as on the web: borderStrong (spec 0x2C3C5A) and
/// the text on the unread colour (spec white, 2.57:1).
public enum Token {
    public static let ground = Color(hex: 0x0B1527)
    public static let surface = Color(hex: 0x0E1B30)
    public static let raised = Color(hex: 0x12213A)
    public static let border = Color(hex: 0x1A2A44)
    public static let borderStrong = Color(hex: 0x5F6C85)
    public static let text = Color(hex: 0xE8EEF9)
    public static let textSecondary = Color(hex: 0xB7C3DA)
    public static let textMuted = Color(hex: 0x7F8EAA)
    public static let signal = Color(hex: 0x37E2E8)
    public static let onSignal = Color(hex: 0x07131F)
    public static let signalTint = Color(hex: 0x37E2E8, opacity: 0.12)
    public static let signalHalo = Color(hex: 0x37E2E8, opacity: 0.18)
    public static let unread = Color(hex: 0xFF7A59)
    public static let onUnread = Color(hex: 0x07131F)
    public static let unreadText = Color(hex: 0xFF9F85)
    public static let unreadTint = Color(hex: 0xFF7A59, opacity: 0.14)
    public static let success = Color(hex: 0x7CF2A6)
    public static let successTint = Color(hex: 0x7CF2A6, opacity: 0.14)
    public static let warning = Color(hex: 0xFFC857)
    public static let warningTint = Color(hex: 0xFFC857, opacity: 0.14)
}

extension View {
    /// The host's navigation bar on the dark surface, with a light title (iOS; the package also builds for macOS tests).
    @ViewBuilder func pulseNavigationBar() -> some View {
        #if os(iOS)
        toolbarBackground(Token.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
