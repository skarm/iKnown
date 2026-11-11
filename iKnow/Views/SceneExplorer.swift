import SwiftUI

struct SceneExplorer: View {
    let source: GraphSource
    let revision: Int
    @State private var threshold = 0.5
    @State private var sections: [ReportSection] = []
    @State private var error: String?

    var body: some View {
        Panel("Scenes in Photos") {
            HStack {
                Text("Confidence at least \(threshold.formatted(.percent.locale(.iKnow).precision(.fractionLength(0))))")
                Slider(value:$threshold,in:0...1,step:0.01)
                    .accessibilityLabel("Minimum Confidence")
                    .frame(maxWidth:280)
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(sections) { section in
                ReportCard(section:section,masked:false,openGraph:{ _ in })
            }
        }
        .task(id: Request(source:source,revision:revision,threshold:threshold)) {
            do {
                try await Task.sleep(for:.milliseconds(150))
                let result = try await ParityReports.scenes(source,threshold:threshold)
                try Task.checkCancellation()
                sections = result
                error = nil
            } catch is CancellationError {
                return
            } catch {
                sections = []
                self.error = error.localizedDescription
            }
        }
    }

    private struct Request: Hashable {
        let source: GraphSource
        let revision: Int
        let threshold: Double
    }
}
