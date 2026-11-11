import SwiftUI

struct SocialNetwork: View {
    let index: SocialIndex
    let source: GraphSource
    let masked: Bool
    var compact = false
    let openGraph: (GraphTarget) -> Void

    @State private var layer: SocialIndex.Kind = .overview
    @State private var closeThreshold = 0.5
    @State private var visibleLayers: Set<SocialIndex.Kind> = [.groups, .work, .events, .closeness, .archive]
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @GestureState private var dragging = CGSize.zero
    @GestureState private var magnification = 1.0
    @State private var pins: [String: CGSize] = [:]
    @State private var movingNode: String?
    @State private var nodeTranslation = CGSize.zero
    @State private var threshold = 0.5
    @State private var sharedAddresses = 2
    @State private var request: SocialDetailRequest?
    @State private var showArchive = true
    @State private var selected: SocialIndex.Node?
    @State private var query = ""

    var body: some View {
        Panel(compact ? "Your Graph" : "Social Connection Map") {
            if !compact && index.layers.count > 1 {
                Picker("Layer", selection: $layer) {
                    ForEach(index.layers) { layer in Text(layer.id.rawValue).tag(layer.id) }
                }
                .pickerStyle(.segmented)
            }
            if let data = index.layers.first(where: { $0.id == layer }) {
                if layer == .overview {
                    HStack {
                        Menu("Layers", systemImage: "square.3.layers.3d") {
                            ForEach(index.layers.filter { [.groups, .work, .events, .closeness, .archive].contains($0.id) }) { item in
                                Toggle(item.id.rawValue, isOn: Binding(
                                    get: { visibleLayers.contains(item.id) },
                                    set: { value in
                                        if value { visibleLayers.insert(item.id) } else { visibleLayers.remove(item.id) }
                                    }
                                ))
                            }
                        }
                        .fixedSize()
                        Label("Family", systemImage: "person.2.fill").foregroundStyle(Palette.indigo)
                        Label("Close Contacts", systemImage: "person.fill").foregroundStyle(.secondary)
                        Label("Retracted", systemImage: "line.diagonal").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if layer == .closeness {
                    HStack {
                        Text("Closeness Threshold \(closeThreshold.formatted(.percent.locale(.iKnow).precision(.fractionLength(0))))")
                        Slider(value: $closeThreshold, in: 0...1, step: 0.05)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Closeness Threshold")
                    }
                    .font(.callout.monospacedDigit())
                }
                if layer == .circles {
                    HStack {
                        Text("Jaccard Threshold \(threshold.formatted(.percent.locale(.iKnow).precision(.fractionLength(0))))")
                            .font(.callout.monospacedDigit())
                        Slider(value:$threshold,in:0.05...0.95,step:0.05)
                            .frame(maxWidth:220)
                            .accessibilityLabel("Jaccard Threshold")
                    }
                }
                if layer == .chats {
                    Stepper("\(sharedAddresses) shared addresses", value: $sharedAddresses, in: 1...10)
                        .frame(maxWidth: 250)
                }
                if layer == .archive {
                    Toggle("Retracted Connections",isOn:$showArchive)
                    Label("Dashed lines indicate archived connections",systemImage:"line.diagonal")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let edges = data.edges.filter {
                    switch layer {
                    case .overview: $0.kind.map(visibleLayers.contains) == true && ($0.kind != .closeness || ($0.weight ?? 0) >= closeThreshold)
                    case .closeness: ($0.weight ?? 0) >= closeThreshold
                    case .circles: ($0.weight ?? 0) >= threshold
                    case .chats: $0.sharedCount >= sharedAddresses
                    case .archive: showArchive || !$0.archived
                    default: true
                    }
                }
                let connected = Set(edges.flatMap { [$0.first, $0.second] })
                let nodes = layer == .overview || layer == .closeness
                    ? data.nodes.filter { connected.contains($0.id) || $0.role == .owner } : data.nodes
                map(nodes, edges: edges)
                    .frame(height: compact ? 380 : 328)
                Text(layer == .circles ? "iKnow calculates connections from shared events." :
                        "Select a node to view related records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !masked {
                    TextField("Find a Node",text:$query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth:240)
                    if !query.isEmpty {
                        ForEach(nodes.filter { $0.title.localizedStandardContains(query) }.prefix(12)) { node in
                            Button(node.title) { selected = node }.buttonStyle(.link)
                        }
                    }
                }
                if let selected, let current = nodes.first(where: { $0.id == selected.id }) {
                    details(current, nodes:data.nodes, edges:edges)
                    if [.groups, .work, .events, .circles, .chats].contains(layer) {
                        Button(data.overlap == nil ? "Original Statements" : "Members and Evidence",
                               systemImage: "list.bullet.rectangle") {
                            request = SocialDetailRequest(source: source, layer: data, node: current, edges: edges)
                        }
                    }
                }
            }
        }
        .sheet(item: $request) { request in
            SocialDetailSheet(request: request, masked: masked) { target in
                self.request = nil
                openGraph(target)
            }
        }
        .onAppear {
            if !index.layers.contains(where: { $0.id == layer }), let first = index.layers.first { layer = first.id }
        }
        .onChange(of: layer) { resetSelection() }
        .onChange(of: source) { resetSelection(); request = nil }
        .onChange(of: masked) { if masked { query = "" } }
    }

    private func resetSelection() {
        selected = nil
        query = ""
        zoom = 1
        pan = .zero
        pins = [:]
    }

    private func map(_ allNodes: [SocialIndex.Node], edges: [SocialIndex.Edge]) -> some View {
        var degree: [String:Int] = [:]
        for edge in edges {
            degree[edge.first,default:0] += 1
            degree[edge.second,default:0] += 1
        }
        let nodes = Array(allNodes.sorted { lhs,rhs in
            if (lhs.role == .owner) != (rhs.role == .owner) { return lhs.role == .owner }
            if lhs.id == selected?.id { return rhs.id != lhs.id }
            if rhs.id == selected?.id { return false }
            let a = degree[lhs.id,default:0], b = degree[rhs.id,default:0]
            return a == b ? lhs.id < rhs.id : a > b
        }.prefix(14))
        return GeometryReader { geometry in
            let size = geometry.size
            let scale = min(3.0, max(0.65, zoom * magnification))
            let positions = layout(nodes, size:size).map { id, point in
                let x = (point.x - size.width / 2) * scale + size.width / 2 + pan.width + dragging.width
                let y = (point.y - size.height / 2) * scale + size.height / 2 + pan.height + dragging.height
                let pin = pins[id] ?? .zero
                let movement = movingNode == id ? nodeTranslation : .zero
                return (id, CGPoint(x: x + pin.width + movement.width, y: y + pin.height + movement.height))
            }
            let points = Dictionary(uniqueKeysWithValues: positions)
            ZStack {
                Canvas { context, _ in
                    for edge in edges {
                        guard let a = points[edge.first],let b = points[edge.second] else { continue }
                        let active = selected?.id == edge.first || selected?.id == edge.second
                        let path = Path { path in path.move(to:a); path.addLine(to:b) }
                        let color = edge.archived ? Palette.peach : Palette.lavender
                        context.stroke(path,with:.color(color.opacity(active ? 0.95 : 0.5)),
                            style:StrokeStyle(lineWidth:active ? 2.6 : 1.2,dash:edge.archived ? [5,4] : []))
                    }
                }
                .accessibilityHidden(true)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 8)
                    .updating($dragging) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    })
                ForEach(nodes) { node in
                    if let position = points[node.id] {
                        let color: Color = switch node.role {
                        case .owner: Palette.mint
                        case .family: Palette.lavender
                        case .close: Color(red: 0.56, green: 0.77, blue: 0.99)
                        case nil: node.isPerson ? .white.opacity(0.82) : Palette.peach
                        }
                        let name = masked ? (node.isPerson ? "Participant" : "Group") : node.title
                        Button {
                            selected = node
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName:node.symbol)
                                    .font(.callout)
                                    .foregroundStyle(Palette.ink)
                                    .frame(width:34,height:34)
                                    .background(color,in:.circle)
                                    .overlay {
                                        if selected?.id == node.id {
                                            Circle().strokeBorder(.white,lineWidth:2)
                                        }
                                    }
                                Text(name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal,4)
                                    .background(Palette.ink,in:.rect(cornerRadius:3))
                            }
                            .frame(width:113,height:56,alignment:.top)
                        }
                        .buttonStyle(.plain)
                        .position(x:position.x,y:position.y+11)
                        .help(name)
                        .accessibilityAddTraits(selected?.id == node.id ? .isSelected : [])
                        .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .named("socialMap"))
                            .onChanged { value in
                                movingNode = node.id
                                nodeTranslation = value.translation
                            }
                            .onEnded { value in
                                var previous = pins[node.id] ?? .zero
                                previous.width += value.translation.width
                                previous.height += value.translation.height
                                pins[node.id] = previous
                                movingNode = nil
                                nodeTranslation = .zero
                            })
                        .contextMenu {
                            if pins[node.id] != nil { Button("Unpin Node") { pins[node.id] = nil } }
                            if let target = node.target { Button("Open in Graph") { openGraph(target) } }
                        }
                    }
                }
                if nodes.isEmpty {
                    Text("No Connections in This Layer")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .coordinateSpace(name: "socialMap")
            .simultaneousGesture(MagnifyGesture()
                .updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = min(3, max(0.65, zoom * value.magnification)) })
            .background(Palette.ink,in:.rect(cornerRadius:12))
            .clipShape(.rect(cornerRadius:12))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(0.65, zoom / 1.25) }
                        .disabled(zoom <= 0.65)
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise") { zoom = 1; pan = .zero; pins = [:] }
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min(3, zoom * 1.25) }
                        .disabled(zoom >= 3)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.5), in: .capsule)
                .padding(10)
            }
        }
    }

    private func layout(_ nodes: [SocialIndex.Node], size: CGSize) -> [String:CGPoint] {
        let center = CGPoint(x:size.width/2,y:size.height/2)
        var result: [String:CGPoint] = [:]
        let centerCount = nodes.count > 2 || nodes.count == 1 ? 1 : 0
        let inner = nodes.count > 8 ? 4 : 0
        for (i,node) in nodes.enumerated() {
            if i < centerCount {
                result[node.id] = center
                continue
            }
            let close = i < inner + centerCount
            let count = close ? inner : nodes.count-inner-centerCount
            let rank = close ? i-centerCount : i-inner-centerCount
            let angle = (close ? -0.7 : -.pi/2) + 2*Double.pi*Double(rank)/Double(count)
            let radius = close ? 0.5 : 1
            result[node.id] = CGPoint(x:center.x+cos(angle)*max(30,center.x-61)*radius,
                                      y:center.y+sin(angle)*max(40,center.y-42)*radius)
        }
        return result
    }

    private func details(_ node: SocialIndex.Node, nodes: [SocialIndex.Node], edges: [SocialIndex.Edge]) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id,$0) })
        let linked = edges.filter { $0.first == node.id || $0.second == node.id }
        return VStack(alignment:.leading,spacing:8) {
            Divider()
            HStack {
                Text(masked ? "Selected Node" : node.title).font(.headline)
                Spacer()
                if let target = node.target {
                    Button("Open in Graph",systemImage:"arrow.up.right") { openGraph(target) }
                }
            }
            if linked.isEmpty {
                Text("No connections at this threshold").foregroundStyle(.secondary)
            }
            ForEach(linked.prefix(15)) { edge in
                let other = edge.first == node.id ? edge.second : edge.first
                HStack {
                    Text(masked ? "Connected Node" : (byID[other]?.title ?? "Connected Node"))
                    Spacer()
                    Text(edge.label).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if linked.count > 15 {
                Text("Showing 15 of \(linked.count) connections").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}


private struct SocialDetailRequest: Identifiable, Sendable {
    let source: GraphSource
    let layer: SocialIndex.Layer
    let node: SocialIndex.Node
    let edges: [SocialIndex.Edge]

    var id: String { "\(layer.id.rawValue)/\(node.id)" }

    @concurrent
    func load() async throws -> [ReportSection] {
        if let overlap = layer.overlap {
            var result = try overlap.sections(in: layer, anchor: node.id, edges: edges)
            if layer.id == .chats, let id = Int64(node.id) {
                result.insert(try source.withScope { try SocialStatements.chatTraffic(source, chatID: id) }, at: 0)
            }
            return result
        }
        return try source.withScope { try SocialStatements.load(source, kind: layer.id, node: node) }
    }
}

private struct SocialDetailSheet: View {
    let request: SocialDetailRequest
    let masked: Bool
    let openGraph: (GraphTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sections: [ReportSection]?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(masked ? "Selected Node" : request.node.title).font(.title2.bold())
                    Text(request.layer.id.rawValue).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if let sections {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(sections) { section in
                            ReportCard(section: section, masked: masked, openGraph: openGraph)
                        }
                    }
                    .padding(20)
                }
            } else if failed {
                ContentUnavailableView("Could Not Read Records", systemImage: "externaldrive.badge.exclamationmark")
            } else {
                ProgressView("Loading evidence…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, idealWidth: 960, minHeight: 520, idealHeight: 640)
        .task {
            do {
                let result = try await request.load()
                try Task.checkCancellation()
                sections = result
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
