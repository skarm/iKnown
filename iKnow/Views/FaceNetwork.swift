import SwiftUI

struct FaceNetwork: View {
    let index: FaceIndex
    let source: GraphSource
    let masked: Bool
    let openGraph: (GraphTarget) -> Void

    @State private var threshold: Double = 2
    @State private var selected: Cluster?
    @State private var search = ""
    @State private var nodePage = 0
    @State private var clusterPage = 0

    private var maximum: Int64 { index.pairs.first?.count ?? 2 }

    var body: some View {
        Panel("Shared Photos") {
            if index.pairs.isEmpty {
                Text("No shared appearances were found in the available database.")
                    .foregroundStyle(.secondary)
            } else {
                let available = index.pairs.filter { $0.count >= Int64(threshold) }
                let clusterIDs = Set(index.clusters.map(\.id))
                let links = available.filter { clusterIDs.contains($0.first) && clusterIDs.contains($0.second) }
                let ranked = rankedNodes(links)
                let page = min(nodePage,max(0,(ranked.count-1)/14))
                let nodes = Array(ranked.dropFirst(page*14).prefix(14))
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("At least \(Int(threshold)) shared photos")
                            .font(.callout.monospacedDigit())
                        Slider(value: $threshold, in: 1...Double(max(2, maximum)), step: 1)
                            .frame(maxWidth: 235)
                            .accessibilityLabel("Minimum Shared Photos")
                        Spacer()
                        Text("\(ranked.count) nodes · \(links.count) pairs")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    network(nodes, links: links)
                        .frame(height: 355)
                    if ranked.count > 14 {
                        pageControls(page:page,count:ranked.count,limit:14,back:{ nodePage = page-1 },next:{ nodePage = page+1 })
                    }
                    Text("Node size represents the photo count. Line weight represents the number of shared photos. Open a cluster to see pairs across pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !index.clusters.isEmpty {
                clusterPicker
            }
        }
        .sheet(item: $selected) { cluster in
            FaceClusterSheet(
                cluster: cluster, index: index, source: source, masked: masked,
                openGraph: { target in
                    selected = nil
                    openGraph(target)
                }
            )
        }
        .onChange(of: masked) { if masked { selected = nil; search = "" } }
        .onChange(of: threshold) { nodePage = 0 }
        .onChange(of: maximum) { threshold = min(threshold,Double(max(2,maximum))) }
        .onChange(of: search) { clusterPage = 0 }
    }

    private var clusterPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Clusters")
                    .font(.headline)
                Spacer()
                if !masked {
                    TextField("Search by name or UUID", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 215)
                }
            }
            let matches = index.clusters.filter {
                search.isEmpty || masked || $0.name.localizedStandardContains(search) || $0.uuid?.localizedStandardContains(search) == true
            }
            if matches.isEmpty {
                Text("No Clusters Found").foregroundStyle(.secondary)
            }
            let page = min(clusterPage,max(0,(matches.count-1)/24))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(matches.dropFirst(page*24).prefix(24)) { cluster in
                    Button {
                        selected = cluster
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(cluster)).lineLimit(1)
                                Text("\(cluster.photos) photos")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.square")
                                .foregroundStyle(Palette.indigo)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            if matches.count > 24 {
                pageControls(page:page,count:matches.count,limit:24,back:{ clusterPage = page-1 },next:{ clusterPage = page+1 })
            }
        }
    }

    private func displayName(_ cluster: Cluster) -> String {
        if masked { return "Cluster \((index.clusters.firstIndex { $0.id == cluster.id } ?? 0) + 1)" }
        return cluster.name
    }

    private func rankedNodes(_ links: [Pair]) -> [Cluster] {
        var weights: [Int64: Int64] = [:]
        for pair in links {
            weights[pair.first, default: 0] += pair.count
            weights[pair.second, default: 0] += pair.count
        }
        return index.clusters.filter { weights[$0.id] != nil }.sorted {
            let lhs = weights[$0.id,default:0]
            let rhs = weights[$1.id,default:0]
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    private func pageControls(page: Int, count: Int, limit: Int, back: @escaping () -> Void, next: @escaping () -> Void) -> some View {
        HStack {
            Text("\(page*limit+1)–\(min(count,(page+1)*limit)) of \(count)").foregroundStyle(.secondary)
            Spacer()
            Button("Previous",systemImage:"chevron.left",action:back).labelStyle(.iconOnly).disabled(page == 0)
            Button("Next",systemImage:"chevron.right",action:next).labelStyle(.iconOnly).disabled((page+1)*limit >= count)
        }
        .buttonStyle(.borderless)
        .font(.caption.monospacedDigit())
    }

    private func network(_ nodes: [Cluster], links: [Pair]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = coordinates(nodes, size: size)
            ZStack {
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 15.0, to: size.width, by: 23) {
                        for y in stride(from: 15.0, to: size.height, by: 23) {
                            grid.addEllipse(in: CGRect(x:x,y:y,width:1.4,height:1.4))
                        }
                    }
                    context.fill(grid, with: .color(.white.opacity(0.16)))
                    for pair in links {
                        guard let a = points[pair.first], let b = points[pair.second] else { continue }
                        let weight = Double(pair.count) / Double(max(1,maximum))
                        let line = Path { path in path.move(to:a); path.addLine(to:b) }
                        context.stroke(line, with: .color(Palette.lavender.opacity(0.26+0.55*weight)), lineWidth: 1+3*weight)
                    }
                }
                .accessibilityHidden(true)
                ForEach(nodes) { cluster in
                    if let position = points[cluster.id] {
                        Button {
                            selected = cluster
                        } label: {
                            let diameter = CGFloat(min(47, 29+sqrt(Double(cluster.photos))))
                            VStack(spacing: 3) {
                                Image(systemName: cluster.graphTargets.isEmpty ? "person" : "person.fill")
                                    .font(.callout)
                                    .frame(width:diameter,height:diameter)
                                    .foregroundStyle(Palette.ink)
                                    .background(cluster.graphTargets.isEmpty ? Palette.lavender : Palette.mint, in: .circle)
                                Text(displayName(cluster))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 3)
                                    .background(Palette.ink, in: .rect(cornerRadius: 3))
                            }
                            .frame(width:98,height:65,alignment:.top)
                        }
                        .buttonStyle(.plain)
                        .position(x:position.x,y:position.y+12)
                        .help(displayName(cluster))
                        .accessibilityHint("Open Cluster")
                    }
                }
                if nodes.isEmpty {
                    Text("No pairs at this threshold")
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
            .background(Palette.ink, in:.rect(cornerRadius:12))
            .clipShape(.rect(cornerRadius:12))
        }
    }

    private func coordinates(_ nodes: [Cluster], size: CGSize) -> [Int64: CGPoint] {
        let center = CGPoint(x:size.width/2,y:size.height/2)
        var result: [Int64: CGPoint] = [:]
        let innerCount = nodes.count > 9 ? 4 : 0
        for (i,node) in nodes.enumerated() {
            let inner = i < innerCount
            let count = inner ? innerCount : nodes.count-innerCount
            let rank = inner ? i : i-innerCount
            let angle = (inner ? -0.6 : -.pi/2) + 2*Double.pi*Double(rank)/Double(count)
            let scale = inner ? 0.51 : 1
            let width = min(340,max(40,size.width/2-57))
            let height = max(45,size.height/2-46)
            result[node.id] = CGPoint(x:center.x+cos(angle)*width*scale,y:center.y+sin(angle)*height*scale)
        }
        return result
    }
}

struct FaceClusterSheet: View {
    let cluster: Cluster
    let index: FaceIndex
    let source: GraphSource
    let masked: Bool
    let openGraph: (GraphTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [FaceAsset]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(masked ? "Cluster" : cluster.name).font(.title.weight(.semibold))
                    Text("\(cluster.faces) faces · \(cluster.photos) photos").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVStack(alignment:.leading,spacing:16) {
                    Panel("Cluster Connections") {
                        if let uuid = cluster.uuid, !masked {
                            Text(uuid).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if cluster.graphTargets.isEmpty {
                            Text("No matching reference in the graph").foregroundStyle(.secondary)
                        } else {
                            ForEach(cluster.graphTargets) { target in
                                Button(masked ? "Open in Graph" : "Open ID \(String(target.id)) in the graph") {
                                    openGraph(target)
                                }
                                .buttonStyle(.link)
                            }
                        }
                        if let verified = cluster.verified {
                            Text("Verification \(verified) · type \(cluster.type ?? 0) · detector \(cluster.detection ?? 0)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    partners
                    Panel("Recent Photos · Up to 24") {
                        if masked {
                            Text("Preview Hidden").foregroundStyle(.secondary)
                        } else if let assets {
                            if assets.isEmpty { Text("No Associated Photos").foregroundStyle(.secondary) }
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:150))],spacing:10) {
                                ForEach(assets) { asset in
                                    AssetPreview(asset:asset,source:source)
                                        .id(asset.path)
                                }
                            }
                        } else if let error {
                            Text(error).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth:660,idealWidth:725,minHeight:520,idealHeight:640)
        .task(id: masked) {
            assets = nil
            error = nil
            guard !masked else { return }
            do {
                let result = try await PhotosReport.assets(source,cluster:cluster)
                try Task.checkCancellation()
                assets = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private var partners: some View {
        let peers = index.pairs.filter { $0.first == cluster.id || $0.second == cluster.id }.prefix(12)
        return Panel("Appearing Together") {
            if peers.isEmpty { Text("No Shared Photos").foregroundStyle(.secondary) }
            ForEach(peers) { pair in
                let peer = pair.first == cluster.id ? pair.second : pair.first
                HStack {
                    Text(masked ? "Related Cluster" : (index.clusters.first { $0.id == peer }?.name ?? "Cluster \(peer)"))
                    Spacer()
                    Text("\(pair.count) photos").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AssetPreview: View {
    let asset: FaceAsset
    let source: GraphSource
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            ZStack {
                RoundedRectangle(cornerRadius:8).fill(.quaternary)
                if let image {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width/CGFloat(image.width),geometry.size.height/CGFloat(image.height))
                        let size = CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
                        ZStack(alignment:.topLeading) {
                            Image(decorative:image,scale:1).resizable().frame(width:size.width,height:size.height)
                            if let point = asset.point, let extent = asset.size, (0...1).contains(extent) {
                                let side = min(size.width,size.height)*extent
                                RoundedRectangle(cornerRadius:3)
                                    .strokeBorder(Palette.mint,lineWidth:1.5)
                                    .frame(width:side,height:side)
                                    .position(x:point.x*size.width,y:point.y*size.height)
                            }
                        }
                        .frame(width:size.width,height:size.height)
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                } else {
                    Label(placeholder,systemImage:"photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height:113)
            .clipShape(.rect(cornerRadius:8))
            if let date = asset.created {
                Text(date,format:.dateTime.day().month(.abbreviated).year())
                    .font(.caption)
            }
            if let quality = asset.quality {
                Text("Quality \(quality.formatted(.number.locale(.iKnow).precision(.fractionLength(2))))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            guard let url = asset.path else { return }
            let result = await PhotosReport.image(url, source: source)
            guard !Task.isCancelled else { return }
            image = result
        }
    }

    private var placeholder: String {
        if asset.hidden { return "Hidden in Photos" }
        if asset.trashed { return "In Trash" }
        return source == .demo ? "Demo Record" : "No Local Preview"
    }
}
