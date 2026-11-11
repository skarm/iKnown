import SwiftUI

struct IdentityCard: View {
    let source: GraphSource
    let target: GraphTarget
    let revision: Int
    let masked: Bool
    let openGraph: (GraphTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detail: GraphDetail?
    @State private var connection: Connection?
    @State private var error: String?

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("Entity Card").font(.title3.weight(.semibold))
                Spacer()
                Button("Open in Graph") {
                    dismiss()
                    openGraph(target)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let detail {
                EvidenceInspector(detail: detail, connection: connection, masked: masked,
                                  showEntity: { connection = nil }, selectConnection: { connection = $0 }) { item in
                    guard let layer = item.layer else { return }
                    dismiss()
                    openGraph(GraphTarget(id: item.id, layer: layer))
                }
            } else if let error {
                ContentUnavailableView(error,systemImage:"exclamationmark.circle")
            } else {
                ProgressView("Loading record…").frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .frame(width:550,height:620)
        .task(id: Request(target: target, revision: revision)) {
            detail = nil
            connection = nil
            error = nil
            do {
                let result = try await GraphRepository.detail(source: source, layer: target.layer, id: target.id)
                try Task.checkCancellation()
                detail = result
                if result == nil { error = "Entity Not Found in This Layer" }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private struct Request: Equatable {
        let target: GraphTarget
        let revision: Int
    }
}
