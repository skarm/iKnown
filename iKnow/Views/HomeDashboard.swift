import SwiftUI

struct HomeDashboard: View {
    let source: GraphSource
    let revision: Int
    let masked: Bool
    let browseGraph: () -> Void
    let open: (Page) -> Void
    let openGraph: (GraphTarget) -> Void
    @State private var snapshot: Snapshot?
    @State private var cluster: Cluster?

    private struct Snapshot {
        let revision: Int
        let cards: [HomeCard]
        let social: SocialIndex?
    }

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        summaryHeading
                        catalogButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        summaryHeading
                        catalogButton
                    }
                }
                if let snapshot {
                    if let social = snapshot.social {
                        SocialNetwork(index: social, source: source, masked: masked, compact: true, openGraph: openGraph)
                    }
                    if let photos = snapshot.cards.first(where: { $0.page == .faces }) {
                        panel(photos, revision: snapshot.revision)
                    }
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:360),spacing:14,alignment:.topLeading)],spacing:14) {
                        ForEach(snapshot.cards.filter { $0.page != .faces }) { card in
                            panel(card, revision: snapshot.revision)
                        }
                    }
                } else {
                    ProgressView("Loading dashboard…")
                }
            }
            .padding(24)
            .frame(maxWidth:1100)
            .frame(maxWidth:.infinity)
        }
        .background(.background.secondary)
        .task(id: revision) {
            async let graph = try? AnalysisRepository.homeSocial(source)
            guard let cards = try? await AnalysisRepository.home(source), !Task.isCancelled else { return }
            let social = await graph
            guard !Task.isCancelled else { return }
            cluster = nil
            snapshot = Snapshot(revision: revision, cards: cards, social: social)
        }
        .sheet(item:$cluster) { selected in
            if let index = snapshot?.cards.first(where: { $0.page == .faces })?.faceIndex {
                FaceClusterSheet(cluster:selected,index:index,source:source,masked:masked) { target in
                    cluster = nil
                    openGraph(target)
                }
            }
        }
    }

    private var summaryHeading: some View {
        PageHeading(title: "Dashboard", subtitle: "People, events, and activity in the selected source", icon: .system("rectangle.grid.2x2"))
    }

    private var catalogButton: some View {
        Button("Open Graph Catalog", systemImage: Page.graphSymbol, action: browseGraph)
            .buttonStyle(.bordered)
            .fixedSize()
    }

    private func panel(_ card: HomeCard, revision: Int) -> some View {
        Panel(card.page.title) {
            HStack(alignment:.firstTextBaseline) {
                Text(card.value.label).font(.title2.monospacedDigit())
                Text(card.detail).font(.callout).foregroundStyle(.secondary)
            }
            if card.value == .empty {
                Text("Source Unavailable").font(.caption).foregroundStyle(.secondary)
            }
            if let index = card.faceIndex {
                ScrollView(.horizontal) {
                    HStack(alignment:.top,spacing:14) {
                        ForEach(index.clusters.filter { $0.faces > 0 }.prefix(12)) { item in
                            Button { cluster = item } label: {
                                HomeFaceTile(cluster:item,source:source,masked:masked,revision:revision)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical,5)
                }
            }
            ForEach(card.rows) { row in
                Divider()
                if let target = row.target {
                    Button { openGraph(target) } label: { entry(row,linked:true) }
                        .buttonStyle(.plain)
                } else {
                    entry(row,linked:false)
                }
            }
            Button("Open Section",systemImage:"arrow.up.right") { open(card.page) }
                .buttonStyle(.link)
                .accessibilityLabel("Open \(card.page.title)")
        }
    }

    private func entry(_ row: HomeEntry, linked: Bool) -> some View {
        HStack(alignment:.top,spacing:10) {
            VStack(alignment:.leading,spacing:3) {
                Text(masked ? "Hidden" : row.title).font(.callout.weight(.medium))
                if !masked && !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength:10)
            if !masked && !row.value.isEmpty {
                Text(row.value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if linked { Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth:.infinity,alignment:.leading)
        .contentShape(.rect)
    }
}

private struct HomeFaceTile: View {
    let cluster: Cluster
    let source: GraphSource
    let masked: Bool
    let revision: Int
    @State private var preview: (request: PreviewRequest, image: CGImage)?

    var body: some View {
        let request = PreviewRequest(revision: revision, masked: masked)
        VStack(spacing:5) {
            ZStack {
                Circle().fill(.quaternary)
                if let preview, preview.request == request, !masked {
                    Image(decorative: preview.image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName:"person.crop.circle").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width:74,height:74)
            .clipShape(.circle)
            .overlay { Circle().strokeBorder(Palette.indigo.opacity(cluster.graphTargets.isEmpty ? 0 : 1),lineWidth:2) }
            Text(masked ? "Cluster" : cluster.name).font(.caption).lineLimit(1)
            Text("\(cluster.photos) photos").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width:100)
        .task(id: request) {
            preview = nil
            guard !masked, let assets = try? await PhotosReport.assets(source,cluster:cluster),
                  let asset = assets.first(where:{ $0.path != nil }), let path = asset.path,
                  let image = await PhotosReport.image(path,source:source), !Task.isCancelled else { return }
            preview = (request, Self.crop(image, asset: asset))
        }
    }

    private struct PreviewRequest: Equatable {
        let revision: Int
        let masked: Bool
    }

    private static func crop(_ image: CGImage, asset: FaceAsset) -> CGImage {
        guard let point = asset.point else { return image }
        let width = Double(image.width), height = Double(image.height)
        let side = min(width,height,max(16,(asset.size ?? 0.2)*min(width,height)*1.7))
        let x = min(width-side,max(0,point.x*width-side/2))
        let y = min(height-side,max(0,point.y*height-side/2))
        return image.cropping(to:CGRect(x:x,y:y,width:side,height:side)) ?? image
    }
}
