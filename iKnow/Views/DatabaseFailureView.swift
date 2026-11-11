import SwiftUI

enum FullDiskAccess {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    )!

    static func canHelp(with failure: GraphFailure) -> Bool {
        switch failure {
        case .permission, .missing, .unreadable: true
        case .busy, .schema: false
        }
    }
}

struct DatabaseFailureView: View {
    let failure: GraphFailure
    let source: GraphSource

    var body: some View {
        ContentUnavailableView {
            Label(failure.localizedDescription, systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if offersSettings {
                Link(destination: FullDiskAccess.settingsURL) {
                    Label("Open Full Disk Access", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
                .help("Open Privacy & Security in System Settings")
            }
        }
    }

    private var offersSettings: Bool {
        source == .mac && FullDiskAccess.canHelp(with: failure)
    }

    private var message: String {
        switch (failure, offersSettings) {
        case (.permission, true):
            "Allow iKnow in Full Disk Access, then relaunch the app."
        case (.missing, true), (.unreadable, true):
            "If macOS is blocking access, check Full Disk Access. You can also choose a database copy or use the demo."
        case (.busy, _):
            "Wait for the database to become available, then click Refresh."
        default:
            "Choose a readable database copy or use the demo from the data source menu."
        }
    }
}
