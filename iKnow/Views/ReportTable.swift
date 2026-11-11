import AppKit
import SwiftUI

struct ReportTable: View {
    struct State {
        var query = ""
        var page = 0
        var level: Cell?
        var sort: Sort?
    }

    struct Sort {
        let column: Int
        let ascending: Bool
    }

    let section: ReportSection
    let masked: Bool
    @Binding var state: State
    let openGraph: (GraphTarget) -> Void

    @SwiftUI.State private var viewportWidth: CGFloat = 0
    private let rowsPerPage = 14
    private let actionWidth: CGFloat = 46

    var body: some View {
        let columns = section.columns.indices.map(columnLayout)
        let rows = visibleRows
        let page = min(state.page, max(0, (rows.count - 1) / rowsPerPage))
        let start = page * rowsPerPage
        let end = min(rows.count, start + rowsPerPage)
        let hasActions = section.targets.contains { $0 != nil }
        let widths = columnWidths(columns, available: viewportWidth - (hasActions ? actionWidth : 0))

        VStack(alignment: .leading, spacing: 10) {
            filters
            if rows.isEmpty {
                Label("No Results", systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(columns, widths: widths, hasActions: hasActions)
                        ForEach(Array(rows[start..<end].enumerated()), id: \.element) { offset, row in
                            ReportTableRow(
                                values: section.rows[row], columns: columns, widths: widths,
                                shaded: offset.isMultiple(of: 2) == false, masked: masked,
                                target: section.targets.indices.contains(row) ? section.targets[row] : nil,
                                actionWidth: hasActions ? actionWidth : nil, openGraph: openGraph
                            )
                        }
                    }
                    .background(.background)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(.primary.opacity(0.10))
                            .allowsHitTesting(false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            }
            if rows.count > rowsPerPage {
                pagination(start: start, end: end, count: rows.count, page: page)
            }
        }
        .onChange(of: state.query) { state.page = 0 }
        .onChange(of: state.level) { state.page = 0 }
    }

    @ViewBuilder private var filters: some View {
        if section.levelColumn != nil || (!masked && section.rows.count > rowsPerPage) {
            HStack(spacing: 10) {
                if let column = section.levelColumn, !masked || !section.columns[column].sensitive {
                    let levels = Set(section.rows.map { $0.indices.contains(column) ? $0[column] : .empty }).sorted { ($0.number ?? 0) > ($1.number ?? 0) }
                    Picker(section.columns[column].title, selection: $state.level) {
                        Text("All Values").tag(nil as Cell?)
                        ForEach(levels, id: \.self) { level in Text(level.label).tag(Optional(level)) }
                    }
                    .frame(maxWidth: 240)
                }
                if !masked && section.rows.count > rowsPerPage {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search table", text: $state.query)
                            .textFieldStyle(.plain)
                        if !state.query.isEmpty {
                            Button("Clear Search", systemImage: "xmark.circle.fill") { state.query = "" }
                                .buttonStyle(.plain)
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .frame(maxWidth: 240)
                    .background(.primary.opacity(0.05), in: .rect(cornerRadius: 7))
                }
            }
        }
    }

    private var visibleRows: [Int] {
        let query = masked ? "" : state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = section.rows.indices.filter { index in
            let row = section.rows[index]
            if let column = section.levelColumn, let level = state.level,
               !masked || !section.columns[column].sensitive,
               (!row.indices.contains(column) || row[column] != level) {
                return false
            }
            return query.isEmpty || row.contains { $0.label.localizedStandardContains(query) }
        }
        guard let sort = state.sort, section.columns.indices.contains(sort.column),
              !masked || !section.columns[sort.column].sensitive else { return filtered }
        return filtered.sorted { first, second in
            let a = section.rows[first], b = section.rows[second]
            let left = a.indices.contains(sort.column) ? a[sort.column] : .empty
            let right = b.indices.contains(sort.column) ? b[sort.column] : .empty
            if left == right { return first < second }
            if left == .empty { return false }
            if right == .empty { return true }
            let order = compare(left, right)
            if order == .orderedSame { return first < second }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func compare(_ left: Cell, _ right: Cell) -> ComparisonResult {
        if case .integer(let a) = left, case .integer(let b) = right {
            return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
        switch (left.number, right.number) {
        case (let a?, let b?): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return left.label.localizedStandardCompare(right.label)
        }
    }

    private func header(_ columns: [ReportTableColumn], widths: [CGFloat], hasActions: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { index in
                let column = columns[index]
                let sorted = state.sort?.column == index && (!masked || !column.info.sensitive)
                let ascending = state.sort?.ascending == true
                let label = HStack(spacing: ReportTableHeaderMetrics.indicatorSpacing) {
                    if column.kind.isNumeric {
                        sortIndicator(ascending: ascending, visible: sorted)
                    }
                    Text(column.info.title)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if !column.kind.isNumeric {
                        sortIndicator(ascending: ascending, visible: sorted)
                    }
                }
                .padding(.horizontal, ReportTableHeaderMetrics.columnInset)
                .frame(minHeight: 38)
                .frame(width: widths[index], alignment: column.kind.isNumeric ? .trailing : .leading)
                .contentShape(.rect)
                .foregroundStyle(sorted ? Palette.indigo : .primary.opacity(0.82))
                if masked && column.info.sensitive {
                    label
                } else {
                    Button {
                        state.sort = Sort(column: index, ascending: sorted ? !ascending : !column.kind.isNumeric)
                        state.page = 0
                    } label: {
                        label
                    }
                    .buttonStyle(.plain)
                    .help("Sort by \(column.info.title)")
                    .accessibilityValue(sorted ? (ascending ? "Ascending" : "Descending") : "")
                }
            }
            if hasActions {
                Color.clear.frame(width: actionWidth, height: 1).accessibilityHidden(true)
            }
        }
        .font(.system(size: ReportTableHeaderMetrics.font.pointSize, weight: .semibold))
        .background(.primary.opacity(0.075))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private func sortIndicator(ascending: Bool, visible: Bool) -> some View {
        Image(systemName: ascending ? "arrow.up" : "arrow.down")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: ReportTableHeaderMetrics.indicatorWidth)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(true)
    }

    private func pagination(start: Int, end: Int, count: Int, page: Int) -> some View {
        HStack(spacing: 7) {
            Text("\(start + 1)–\(end) of \(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Previous Page", systemImage: "chevron.left") { state.page = page - 1 }
                .disabled(start == 0)
            Button("Next Page", systemImage: "chevron.right") { state.page = page + 1 }
                .disabled(end == count)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func columnLayout(_ index: Int) -> ReportTableColumn {
        let info = section.columns[index]
        let samples = section.rows.prefix(64).compactMap { row -> Cell? in
            guard row.indices.contains(index), row[index] != .empty else { return nil }
            return row[index]
        }
        let numeric = !samples.isEmpty && samples.allSatisfy { $0.number != nil }
        let kind: ReportTableColumn.Kind = switch info.format {
        case .automatic: section.style == .scores && index > 0 ? .matrix : (numeric ? .number : .text)
        case .code: .code
        case .layer: .layer
        case .score: .score
        case .percent: .percent
        case .people: .people
        }

        let header = ReportTableHeaderMetrics.minimumWidth(for: info.title)
        let sampleLength = masked && info.sensitive ? 0 : CGFloat(samples.lazy.map { $0.label.count }.max() ?? 0)
        let minimum: CGFloat
        let preferred: CGFloat
        switch kind {
        case .number, .matrix:
            minimum = 65
            preferred = min(138, max(70, sampleLength * 7 + 28))
        case .score, .percent:
            minimum = 92
            preferred = max(minimum, min(135, header))
        case .layer:
            minimum = 152
            preferred = 182
        case .code:
            minimum = 112
            preferred = max(minimum, min(225, sampleLength * 7 + 24))
        case .people:
            minimum = 242
            preferred = 435
        case .text:
            minimum = index == 0 ? 142 : 114
            preferred = max(minimum, min(284, max(header, sampleLength * 6.3 + 24)))
        }
        let measuredMinimum = max(minimum, header)
        return .init(info: info, kind: kind, minimum: measuredMinimum, preferred: max(measuredMinimum, preferred))
    }

    private func columnWidths(_ columns: [ReportTableColumn], available: CGFloat) -> [CGFloat] {
        let minimum = columns.reduce(CGFloat(0)) { $0 + $1.minimum }
        let preferred = columns.reduce(CGFloat(0)) { $0 + $1.preferred }
        let fraction = available == 0 ? 1 : min(1, max(0, (available - minimum) / max(1, preferred - minimum)))
        var widths = columns.map { $0.minimum + ($0.preferred - $0.minimum) * fraction }
        let extra = available - preferred
        if extra > 0 {
            let people = columns.indices.filter { columns[$0].kind == .people }
            if !people.isEmpty {
                for index in people { widths[index] += min(180, extra / CGFloat(people.count)) }
            } else {
                let text = columns.indices.filter { columns[$0].kind == .text }
                for index in text { widths[index] += min(45, extra / CGFloat(text.count)) }
            }
        }
        return widths
    }
}

@MainActor
private enum ReportTableHeaderMetrics {
    static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    static let columnInset: CGFloat = 11
    static let indicatorWidth: CGFloat = 10
    static let indicatorSpacing: CGFloat = 5

    static func minimumWidth(for title: String) -> CGFloat {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return textWidth + 2 * columnInset + indicatorWidth + indicatorSpacing + 2
    }
}

private struct ReportTableColumn {
    enum Kind {
        case text, number, code, layer, score, percent, people, matrix

        var isNumeric: Bool {
            switch self {
            case .number, .score, .percent, .matrix: true
            case .text, .code, .layer, .people: false
            }
        }
    }

    let info: Column
    let kind: Kind
    let minimum: CGFloat
    let preferred: CGFloat
}

private struct ReportTableRow: View {
    let values: [Cell]
    let columns: [ReportTableColumn]
    let widths: [CGFloat]
    let shaded: Bool
    let masked: Bool
    let target: GraphTarget?
    let actionWidth: CGFloat?
    let openGraph: (GraphTarget) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                let alignment: Alignment = column.kind.isNumeric ? .trailing : .leading
                cell(values.indices.contains(index) ? values[index] : .empty, column: column, isFirst: index == 0)
                    .padding(.horizontal, ReportTableHeaderMetrics.columnInset)
                    .padding(.vertical, 7)
                    .frame(width: widths[index], alignment: alignment)
            }
            if let actionWidth {
                Group {
                    if let target {
                        Button("Card", systemImage: "arrow.up.right") { openGraph(target) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Open Entity Card")
                    } else {
                        Color.clear.frame(height: 1).accessibilityHidden(true)
                    }
                }
                .frame(width: actionWidth)
            }
        }
        .frame(minHeight: 39)
        .background(hovered ? Palette.indigo.opacity(0.085) : .primary.opacity(shaded ? 0.038 : 0))
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func cell(_ value: Cell, column: ReportTableColumn, isFirst: Bool) -> some View {
        if masked && column.info.sensitive {
            Text("Hidden").font(.callout).foregroundStyle(.secondary)
        } else if value == .empty {
            Text("—").font(.callout).foregroundStyle(.secondary)
        } else {
            switch column.kind {
            case .code:
                Text(value.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value.label)
            case .layer:
                let symbol = GraphLayer.allCases.first { $0.title == value.label }?.symbol ?? "square.3.layers.3d"
                Label(value.label, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.075), in: .rect(cornerRadius: 5))
                    .help(value.label)
            case .score, .percent, .matrix:
                score(value, kind: column.kind)
            case .people:
                if case .names(let names) = value {
                    ParticipantNames(names: names)
                } else {
                    Text(value.label).font(.callout)
                }
            case .number:
                Text(value.label)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                    .help(value.label)
            case .text:
                Text(value.label)
                    .font(.callout.weight(isFirst ? .semibold : .regular))
                    .lineLimit(3)
                    .help(value.label)
            }
        }
    }

    private func score(_ value: Cell, kind: ReportTableColumn.Kind) -> some View {
        let normalized = value.number.flatMap { (0...1).contains($0) ? $0 : nil }
        let text = kind == .percent ? (normalized?.formatted(.percent.locale(.iKnow).precision(.fractionLength(0...1))) ?? value.label) : value.label
        return HStack(spacing: 6) {
            if kind != .matrix, let normalized {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.09))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Palette.indigo.opacity(0.70))
                                .frame(width: geometry.size.width * normalized)
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            } else {
                Spacer(minLength: 0)
            }
            Text(text)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
        }
        .padding(.horizontal, kind == .matrix ? 6 : 0)
        .padding(.vertical, 3)
        .background {
            if kind == .matrix, let normalized, normalized > 0 {
                RoundedRectangle(cornerRadius: 4).fill(Palette.indigo.opacity(normalized * 0.30))
            }
        }
        .help(value.label)
    }

}

private struct ParticipantNames: View {
    let names: [String]
    @State private var showingAll = false
    private let previewCount = 5

    var body: some View {
        ParticipantFlow {
            ForEach(Array(names.prefix(previewCount).enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.indigo.opacity(0.10), in: .capsule)
                    .help(name)
            }
            if names.count > previewCount {
                Button("\(names.count - previewCount) more") { showingAll = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Participants").font(.headline)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                                        Text(name).font(.callout)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: min(280, CGFloat(names.count) * 24))
                        }
                        .padding(15)
                        .frame(width: 250)
                    }
            }
        }
    }
}

private struct ParticipantFlow: Layout {
    private let spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        placement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = placement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func placement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: widest, height: y + lineHeight), frames)
    }
}
