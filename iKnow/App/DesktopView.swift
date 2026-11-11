import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Palette {
    static let ink = Color(red: 0.050, green: 0.109, blue: 0.156)
    static let indigo = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.56, green: 0.74, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.12, green: 0.36, blue: 0.66, alpha: 1)
    })
    static let lavender = Color(red: 0.76, green: 0.72, blue: 1)
    static let mint = Color(red: 0.48, green: 0.90, blue: 0.80)
    static let peach = Color(red: 1, green: 0.76, blue: 0.59)
    static let sky = Color(red: 0.58, green: 0.80, blue: 1)
    static let plotDeep = Color(red: 0.035, green: 0.075, blue: 0.12)

    static func entityTint(_ entity: Entity?) -> Color {
        if entity?.isOwner == true { return .teal }
        return switch entity?.classCode {
        case "SB104": indigo
        case "SB10": .orange
        case "SB2": .purple
        case "SB65", "SB472", "SB514": .pink
        case "SB144": .teal
        default: .secondary
        }
    }
}

struct DesktopView: View {
    private enum Destination: Equatable {
        case catalog
        case summary
        case report(Page)
    }

    private enum StartupSource: String {
        case demo
        case mac

        var graphSource: GraphSource {
            switch self {
            case .demo: .demo
            case .mac: .mac
            }
        }
    }

    @AppStorage("sidebarPinned") private var sidebarPinned = true
    @AppStorage("startupSource") private var startupSource: StartupSource?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pixelLength) private var pixelLength
    @State private var destination: Destination = .catalog
    @State private var importedSource: GraphSource?
    @State private var revision = 0
    @State private var masked = false
    @State private var importing = false
    @State private var importingFolder = false
    @State private var importFailed = false
    @State private var graphTarget: GraphTarget?
    @State private var sidebarRevealed = false
    @State private var pointerOverSidebar = false

    private let sidebarWidth: CGFloat = 224
    private let compactSidebarWidth: CGFloat = 52
    private let sidebarInset: CGFloat = 8

    private var sidebarExpanded: Bool { sidebarPinned || sidebarRevealed }
    private var sidebarIconWidth: CGFloat { compactSidebarWidth - 2 * sidebarInset }
    private var source: GraphSource { importedSource ?? startupSource?.graphSource ?? .demo }

    var body: some View {
        Group {
            if startupSource == nil {
                SourceSetupView(selectSource: switchSource)
            } else {
                desktop
            }
        }
        .background(.background)
        .navigationTitle("iKnow")
        .tint(Palette.indigo)
    }

    private var desktop: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: sidebarPinned ? sidebarWidth : compactSidebarWidth)
                .accessibilityHidden(true)
            detail
                .id(source)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .leading) { sidebarPanel }
        .toolbar { controls }
        .fileImporter(isPresented: $importing, allowedContentTypes: importingFolder ? [.folder] : [.item]) { result in
            switch result {
            case .success(let url): switchSource(importingFolder ? .bundle(url) : .file(url))
            case .failure: importFailed = true
            }
        }
        .alert("Could Not Open Source", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var sidebarPanel: some View {
        sidebar
            .frame(width: sidebarExpanded ? sidebarWidth : compactSidebarWidth)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: pixelLength)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(!sidebarPinned && sidebarRevealed ? 0.23 : 0),
                    radius: 13, x: 5)
            .background {
                if !sidebarPinned {
                    SidebarTrackingArea { inside in
                        pointerOverSidebar = inside
                        if inside { sidebarRevealed = true }
                    }
                    .accessibilityHidden(true)
                }
            }
            .task(id: pointerOverSidebar) {
                guard !sidebarPinned, !pointerOverSidebar, sidebarRevealed else { return }
                try? await Task.sleep(for: .milliseconds(180))
                if !Task.isCancelled { sidebarRevealed = false }
            }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 2) {
                        sidebarRow("Graph Catalog", icon: Page.graph.icon, item: .catalog)
                        sidebarRow("Dashboard", icon: .system("rectangle.grid.2x2"), item: .summary)
                        sidebarRow(Page.social.title, icon: Page.social.icon, item: .report(.social))
                    }
                    sidebarGroup("Personal Data", [.kinship, .communications, .faces, .calendar, .identity])
                    sidebarGroup("Device", [.store, .certainty, .retractions, .apps, .consumers])
                }
                .padding(.horizontal, sidebarInset)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .accessibilityLabel("iKnow Sections")
            Divider().padding(.horizontal, 14)
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .frame(width: sidebarIconWidth)
                if sidebarExpanded {
                    Text("Read Only")
                    Spacer(minLength: 0)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, sidebarInset)
            .padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Read Only")
            .help("Read Only")
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 5) {
            Image(decorative: "BrandMark")
                .resizable()
                .frame(width: 21, height: 21)
                .frame(width: 31, height: 31)
                .background(Palette.ink, in: .rect(cornerRadius: 9))
                .frame(width: sidebarIconWidth)
            if sidebarExpanded {
                Text("iKnow")
                    .font(.system(size: 18, weight: .semibold))
                    .transition(.opacity)
                Spacer(minLength: 0)
                if !sidebarPinned {
                    Button("Pin Sidebar", systemImage: "pin", action: toggleSidebar)
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Pin Sidebar")
                }
            }
        }
        .padding(.horizontal, sidebarInset)
        .padding(.trailing, sidebarExpanded ? 5 : 0)
        .padding(.vertical, 14)
    }

    private func sidebarGroup(_ title: String, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if sidebarExpanded {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 17, height: 1)
                        .frame(width: sidebarIconWidth)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 17)
            ForEach(pages) { page in
                sidebarRow(page == .consumers ? "Stores and Subscriptions" : page.title,
                           icon: page.icon, item: .report(page))
            }
        }
    }

    private func sidebarRow(_ title: String, icon: SectionIcon, item: Destination) -> some View {
        let selected = destination == item
        return Button { navigate(to: item) } label: {
            HStack(spacing: 4) {
                SectionGlyph(icon: icon, size: 15)
                    .foregroundStyle(selected ? Palette.indigo : .secondary)
                    .frame(width: sidebarIconWidth)
                    .accessibilityHidden(true)
                if sidebarExpanded {
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
            }
            .padding(.trailing, sidebarExpanded ? 6 : 0)
            .frame(height: 32)
            .background(selected ? Palette.indigo.opacity(0.12) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: sidebarExpanded)
        }
        .buttonStyle(SidebarButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    @ViewBuilder private var detail: some View {
        switch destination {
        case .catalog:
            WorkspaceView(source: source, revision: revision, masked: masked, target: graphTarget) { target in
                graphTarget = target
            }
        case .summary:
            HomeDashboard(source: source, revision: revision, masked: masked,
                          browseGraph: { navigate(to: .catalog) },
                          open: { navigate(to: .report($0)) }, openGraph: openGraph)
        case .report(let page):
            ReportView(page: page, source: source, revision: revision, masked: masked, openGraph: openGraph)
                .id(page)
        }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            let title = sidebarPinned ? "Collapse Sidebar" : "Expand Sidebar"
            Button(title, systemImage: "sidebar.left", action: toggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .option])
                .help(title)
                .accessibilityHint(sidebarPinned ? "Hover over the icons to show their labels" : "Keep the sidebar expanded")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Demo", systemImage: "sparkle.magnifyingglass") { switchSource(.demo) }
                Button("This Mac", systemImage: "desktopcomputer") { switchSource(.mac) }
                Divider()
                Button("Open a Copy of graph.db…", systemImage: "doc") {
                    importingFolder = false
                    importing = true
                }
                .keyboardShortcut("o")
                Button("Open a Store Snapshot…", systemImage: "folder") {
                    importingFolder = true
                    importing = true
                }
            } label: {
                Text(source.title)
            }
            .help("Choose a data source")
            .accessibilityLabel("Data Source")
            .accessibilityValue(source.title)

            Button {
                masked.toggle()
            } label: {
                Label(masked ? "Show Personal Data" : "Hide Personal Data",
                      systemImage: masked ? "eye.slash.fill" : "eye")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(masked ? "Show Personal Data" : "Hide names, addresses, IDs, and photos")

            Button("Refresh", systemImage: "arrow.clockwise") { revision += 1 }
                .keyboardShortcut("r")
                .help("Reload the data")
        }
    }

    private func navigate(to item: Destination) {
        destination = item
    }

    private func openGraph(_ target: GraphTarget) {
        graphTarget = target
        navigate(to: .catalog)
    }

    private func toggleSidebar() {
        sidebarRevealed = false
        pointerOverSidebar = false
        sidebarPinned.toggle()
    }

    private func switchSource(_ next: GraphSource) {
        guard startupSource == nil || next != source else { return }
        graphTarget = nil
        switch next {
        case .demo:
            startupSource = .demo
            importedSource = nil
        case .mac:
            startupSource = .mac
            importedSource = nil
        case .file, .bundle:
            importedSource = next
        }
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(.primary.opacity(hovered && isEnabled ? (configuration.isPressed ? 0.10 : 0.04) : 0),
                            in: .rect(cornerRadius: 7))
                .onHover { hovered = $0 }
        }
    }
}

private struct SidebarTrackingArea: NSViewRepresentable {
    let updatePresence: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(frame: .zero)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.updatePresence = updatePresence
    }

    final class TrackingView: NSView {
        var updatePresence: ((Bool) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow,
                                                   .inVisibleRect, .enabledDuringMouseDrag]
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) { checkPresence(event) }
        override func mouseExited(with event: NSEvent) { checkPresence(event) }

        private func checkPresence(_ event: NSEvent) {
            // The reveal widens the tracking area. Use the current bounds for queued events.
            updatePresence?(bounds.contains(convert(event.locationInWindow, from: nil)))
        }
    }
}
