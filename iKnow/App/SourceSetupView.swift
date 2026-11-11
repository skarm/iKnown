import SwiftUI

struct SourceSetupView: View {
    let selectSource: (GraphSource) -> Void

    @Environment(\.openURL) private var openURL
    @State private var checkingMac = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(decorative: "BrandMark")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .frame(width: 54, height: 54)
                    .background(Palette.ink, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to iKnow")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose a data source for your graph.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                sourceCard("Demo Data", icon: "sparkle.magnifyingglass",
                           description: "Explore a sample graph without granting access to files on your Mac.") {
                    Button("Explore Demo") {
                        checkingMac = false
                        selectSource(.demo)
                    }
                    .buttonStyle(.bordered)
                }
                sourceCard("This Mac", icon: "desktopcomputer",
                           description: "Open the graph stored on this Mac in read-only mode. Set up Full Disk Access if needed.") {
                    Button("Set Up This Mac") { checkingMac = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(checkingMac)
                    if checkingMac {
                        ProgressView("Checking access…")
                            .controlSize(.small)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 650)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: checkingMac) {
            guard checkingMac else { return }
            let failure = await Self.checkMac()
            guard checkingMac, !Task.isCancelled else { return }
            selectSource(.mac)
            if let failure, FullDiskAccess.canHelp(with: failure) {
                openURL(FullDiskAccess.settingsURL)
            }
        }
    }

    private func sourceCard<Actions: View>(
        _ title: LocalizedStringKey, icon: String, description: LocalizedStringKey,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(description)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 8, content: actions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @concurrent private static func checkMac() async -> GraphFailure? {
        do {
            _ = try GraphAccess(.mac)
            return nil
        } catch {
            return (error as? GraphFailure) ?? .unreadable
        }
    }
}
