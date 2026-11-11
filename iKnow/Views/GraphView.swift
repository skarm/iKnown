import SwiftUI

struct GraphView: View {
    let detail: GraphDetail
    let layer: GraphLayer
    let selection: Int64?
    let masked: Bool
    @Binding var showingInspector: Bool
    let select: (Int64?) -> Void

    private var entityName: String { masked ? "Selected Entity" : detail.entity.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            GraphCanvas(detail: detail, selection: selection, masked: masked, entityName: entityName, select: select)
                .id(detail.entity.id)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(layer.title, systemImage: layer.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(showingInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
                    showingInspector.toggle()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showingInspector ? "Hide Inspector" : "Show Inspector")
            }
            Text(entityName)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.8)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Text(detail.entity.isOwner ? "Mac Owner" : detail.entity.kind)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 3)
    }

    private var footer: some View {
        let connections = detail.hasMoreConnections ? "\(detail.connections.count)+" : detail.connections.count.formatted(.number.locale(.iKnow))
        let facts = detail.hasMoreStatements ? "\(detail.statements.count)+" : detail.statements.count.formatted(.number.locale(.iKnow))
        return HStack(spacing: 12) {
            Label("Connections \(connections)", systemImage: "point.3.connected.trianglepath.dotted")
            Label("Statements \(facts)", systemImage: "text.alignleft")
            Spacer(minLength: 0)
            if !showingInspector {
                Button("Show Records") {
                    select(nil)
                }
                .buttonStyle(.link)
                .lineLimit(1)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
    }
}

private struct GraphCanvas: View {
    let detail: GraphDetail
    let selection: Int64?
    let masked: Bool
    let entityName: String
    let select: (Int64?) -> Void

    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            plotHeader
            GeometryReader { geometry in
                let size = geometry.size
                let frameCenter = CGPoint(x: size.width / 2, y: size.height / 2)
                let center = CGPoint(x: frameCenter.x + pan.width + drag.width, y: frameCenter.y + pan.height + drag.height)
                let scale = clamped(zoom * pinch)
                let nodes = positions(size, center: center, scale: scale)
                ZStack {
                    Canvas { context, size in
                        draw(context, size: size, center: center, nodes: nodes, scale: scale)
                    }
                    .accessibilityHidden(true)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                pan.width += value.translation.width
                                pan.height += value.translation.height
                            }
                    )

                    ForEach(nodes) { node in
                        let selected = node.connection.id == selection
                        let name = masked ? "Connection \(node.rank)" : node.connection.name
                        GraphNodeButton(
                            name: name, symbol: node.connection.entity?.symbol ?? "circle.dotted",
                            color: color(for: node.connection), selected: selected, isCenter: false
                        ) { select(node.connection.id) }
                        .position(x: node.position.x, y: node.position.y + 10)
                        .zIndex(selected ? 1 : 0)
                    }

                    GraphNodeButton(name: entityName, symbol: detail.entity.symbol, color: Palette.mint,
                                    selected: selection == nil, isCenter: true) { select(nil) }
                        .position(center)
                        .zIndex(2)
                }
                .clipped()
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { zoom = clamped(zoom * $0.magnification) }
                )
            }
            .frame(minHeight: 190)
            plotFooter
        }
        .foregroundStyle(.white)
        .background {
            ZStack {
                Palette.plotDeep
                RadialGradient(colors: [Color(red: 0.10, green: 0.25, blue: 0.33), Palette.plotDeep],
                               center: .center, startRadius: 22, endRadius: 450)
            }
        }
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12))
                .allowsHitTesting(false)
        }
    }

    private var plotHeader: some View {
        HStack {
            Label("Connection Map", systemImage: "scope")
                .font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 1) {
                zoomButton("Zoom Out", symbol: "minus") { zoom = clamped(zoom / 1.25) }
                    .disabled(zoom <= 0.7)
                Button {
                    zoom = 1
                    pan = .zero
                } label: {
                    Text(Double(zoom).formatted(.percent.locale(.iKnow).precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 43, minHeight: 26)
                }
                .buttonStyle(.plain)
                .help("Reset Zoom and Position")
                .accessibilityLabel("Reset Zoom and Position")
                .accessibilityValue(Double(zoom).formatted(.percent.locale(.iKnow).precision(.fractionLength(0))))
                zoomButton("Zoom In", symbol: "plus") { zoom = clamped(zoom * 1.25) }
                    .disabled(zoom >= 2.5)
            }
            .padding(2)
            .background(.white.opacity(0.085), in: .rect(cornerRadius: 7))
        }
        .padding(.horizontal, 13)
        .padding(.top, 12)
    }

    private var plotFooter: some View {
        HStack(spacing: 6) {
            if detail.connections.isEmpty {
                Text("This layer has no direct connections")
            } else {
                Image(systemName: "arrow.right").accessibilityHidden(true)
                Text("Arrows show the direction of records")
            }
            Spacer(minLength: 4)
            if detail.connections.count > 8 {
                Text("See all connections in the inspector")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 13)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private func zoomButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .font(.caption.weight(.semibold))
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 27, height: 26)
            .help(title)
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(2.5, max(0.7, value)) }

    private struct NodePoint: Identifiable {
        let connection: Connection
        let position: CGPoint
        let rank: Int
        var id: Int64 { connection.id }
    }

    private func positions(_ size: CGSize, center: CGPoint, scale: CGFloat) -> [NodePoint] {
        let limit = size.width < 360 || size.height < 280 ? 8 : 12
        let items = Array(detail.connections.prefix(limit))
        let innerCount = items.count > 8 ? 4 : 0
        let outerX = max(70, min(size.width / 2 - 57, 296)) * scale
        let outerY = max(62, min(size.height / 2 - 37, 226)) * scale
        return items.enumerated().map { offset, connection in
            let inner = offset < innerCount
            let count = inner ? innerCount : items.count - innerCount
            let index = inner ? offset : offset - innerCount
            let start = count == 1 ? -Double.pi / 3 : -.pi / 2 + (inner ? .pi / 4 : 0)
            let angle = start + 2 * Double.pi * Double(index) / Double(count)
            let distance = inner ? 0.55 : 1
            let point = CGPoint(x: center.x + cos(angle) * outerX * distance,
                                y: center.y + sin(angle) * outerY * distance)
            return NodePoint(connection: connection, position: point, rank: offset + 1)
        }
    }

    private func color(for connection: Connection) -> Color {
        switch connection.entity?.classCode {
        case "SB104": Palette.sky
        case "SB10": Palette.peach
        case "SB2": Palette.lavender
        case "SB65", "SB472", "SB514": Color(red: 1, green: 0.70, blue: 0.78)
        default: Palette.mint
        }
    }

    private func draw(_ context: GraphicsContext, size: CGSize, center: CGPoint, nodes: [NodePoint], scale: CGFloat) {
        var dots = Path()
        for x in stride(from: 12.0, to: size.width, by: 20) {
            for y in stride(from: 12.0, to: size.height, by: 20) {
                dots.addEllipse(in: CGRect(x: x, y: y, width: 1.15, height: 1.15))
            }
        }
        context.fill(dots, with: .color(.white.opacity(0.14)))
        for radius in [44.0, 74, 108] {
            let r = radius * scale
            let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(Palette.sky.opacity(0.15)),
                           style: StrokeStyle(lineWidth: 1, dash: radius == 44 ? [] : [2, 5]))
        }

        for item in nodes {
            let end = item.position
            let color = color(for: item.connection)
            let selected = item.connection.id == selection
            let dx = end.x - center.x
            let dy = end.y - center.y
            guard hypot(dx, dy) > 58 else { continue }
            let angle = atan2(dy, dx)
            let from = CGPoint(x: center.x + 35 * cos(angle), y: center.y + 35 * sin(angle))
            let to = CGPoint(x: end.x - 20 * cos(angle), y: end.y - 20 * sin(angle))
            var edge = Path()
            edge.move(to: from)
            edge.addLine(to: to)
            if !item.connection.outgoing.isEmpty { arrow(&edge, at: to, angle: angle) }
            if !item.connection.incoming.isEmpty { arrow(&edge, at: from, angle: angle + .pi) }
            let opacity = selected ? 0.95 : (selection == nil ? 0.58 : 0.27)
            context.stroke(edge, with: .color(color.opacity(opacity)),
                           style: StrokeStyle(lineWidth: selected ? 2 : 1, lineCap: .round, lineJoin: .round))
        }
    }

    private func arrow(_ path: inout Path, at point: CGPoint, angle: Double) {
        for delta in [-0.52, 0.52] {
            path.move(to: point)
            path.addLine(to: CGPoint(x: point.x - 6 * cos(angle + delta), y: point.y - 6 * sin(angle + delta)))
        }
    }
}

private struct GraphNodeButton: View {
    let name: String
    let symbol: String
    let color: Color
    let selected: Bool
    let isCenter: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let active = isCenter || hovered || selected
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: isCenter ? 22 : 14, weight: .semibold))
                    .foregroundStyle(active ? Palette.plotDeep : color)
                    .frame(width: isCenter ? 57 : 34, height: isCenter ? 57 : 34)
                    .background(active ? color : Palette.ink, in: .circle)
                    .overlay { Circle().strokeBorder(color.opacity(0.86), lineWidth: 1) }
                    .shadow(color: color.opacity(active ? 0.24 : 0), radius: isCenter ? 13 : 8)
                if !isCenter {
                    Text(name)
                        .font(.caption2.weight(active ? .semibold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Palette.plotDeep.opacity(0.92), in: .rect(cornerRadius: 4))
                }
            }
            .frame(width: isCenter ? 62 : 100, height: isCenter ? 62 : 54, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityHint(isCenter ? "Show entity records" : "Show connection records")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
