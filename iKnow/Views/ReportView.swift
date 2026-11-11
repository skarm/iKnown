import Charts
import SwiftUI

struct ReportView: View {
    let page: Page
    let source: GraphSource
    let revision: Int
    let masked: Bool
    let openGraph: (GraphTarget) -> Void

    @State private var result: Result<Report, GraphFailure>?
    @State private var inspected: GraphTarget?

    var body: some View {
        Group {
            switch result {
            case .success(let report):
                content(report)
            case .failure(let failure):
                DatabaseFailureView(failure: failure, source: source)
            case nil:
                ProgressView("Loading data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item:$inspected) { target in
            IdentityCard(source: source, target: target, revision: revision, masked: masked, openGraph: openGraph)
        }
        .task(id: revision) { await load() }
    }

    private func content(_ report: Report) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ReportHeader(page: page, metrics: report.metrics)
                    HStack {
                        if page == .communications {
                            Label("Log Metadata", systemImage: "bubble")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !report.sections.isEmpty {
                            Menu {
                                if report.faces != nil {
                                    Button("Shared Photos") { scroll.scrollTo("faces", anchor: .top) }
                                }
                                ForEach(report.sections) { section in
                                    Button(section.title) { scroll.scrollTo(section.id, anchor: .top) }
                                }
                            } label: {
                                Label("Jump to Section", systemImage: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    .padding(.horizontal, 2)
                    if let faces = report.faces {
                        FaceNetwork(index: faces, source: source, masked: masked, openGraph: openGraph)
                            .id("faces")
                    }
                    if let social = report.social {
                        SocialNetwork(index: social, source: source, masked: masked, openGraph: openGraph)
                    }
                    if let index = report.tokens, !masked {
                        TokenCheck(index:index)
                    }
                    if report.hasSceneJoin {
                        SceneExplorer(source:source,revision:revision)
                    }
                    ForEach(report.sections) { section in
                        ReportCard(section: section, masked: masked) { inspected = $0 }
                            .id(section.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 1_280)
                .frame(maxWidth: .infinity)
            }
        }
        .background(.background.secondary)
    }

    private func load() async {
        do {
            let report = try await AnalysisRepository.load(page, source: source)
            try Task.checkCancellation()
            result = .success(report)
        } catch {
            guard !Task.isCancelled else { return }
            inspected = nil
            result = .failure((error as? GraphFailure) ?? .unreadable)
        }
    }
}

private struct ReportHeader: View {
    let page: Page
    let metrics: [Metric]

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            PageHeading(title: page.title, subtitle: page.subtitle, icon: page.icon)
            if !metrics.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 143), spacing: 8, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.value)
                                .font(.system(size: 21, weight: .semibold).monospacedDigit())
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                            Text(metric.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
                        .padding(11)
                        .background(.background, in: .rect(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(.primary.opacity(0.07))
                                .allowsHitTesting(false)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    let icon: SectionIcon

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            SectionGlyph(icon: icon, size: 21)
                .foregroundStyle(Palette.indigo)
                .frame(width: 44, height: 44)
                .background(Palette.indigo.opacity(0.10), in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 29, weight: .semibold))
                    .tracking(-0.65)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Panel<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.system(.title3, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct ReportCard: View {
    let section: ReportSection
    let masked: Bool
    let openGraph: (GraphTarget) -> Void

    @State private var tableState = ReportTable.State()

    var body: some View {
        Panel(section.title) {
            if let note = section.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if section.rows.isEmpty {
                Label(section.unavailable ? "Section Unavailable" : "No Records",
                      systemImage: section.unavailable ? "exclamationmark.circle" : "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                switch section.style {
                case .table, .scores:
                    table
                case .weekly, .bars, .series:
                    if section.style == .weekly {
                        WeeklyChart(rows: section.rows)
                    } else {
                        SeriesChart(section: section)
                    }
                    ExpandableRow("Exact Values") {
                        table.padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
        }
        .onChange(of: masked) {
            tableState.page = 0
            if masked {
                tableState.query = ""
                if let sort = tableState.sort, !section.columns.indices.contains(sort.column) || section.columns[sort.column].sensitive {
                    tableState.sort = nil
                }
                if let column = section.levelColumn, section.columns[column].sensitive { tableState.level = nil }
            }
        }
    }

    private var table: some View {
        ReportTable(section: section, masked: masked, state: $tableState, openGraph: openGraph)
    }
}

private struct SeriesChart: View {
    let section: ReportSection

    private struct Mark: Identifiable {
        let category: String
        let series: String
        let amount: Double
        var id: String { category + "\u{1e}" + series }
    }

    private var points: [Mark] {
        section.rows.suffix(36).flatMap { row -> [Mark] in
            guard let category = row.first?.label else { return [] }
            return row.indices.dropFirst().compactMap { index in
                guard section.columns.indices.contains(index), let amount = row[index].number else { return nil }
                return Mark(category: category, series: section.columns[index].title, amount: amount)
            }
        }
    }

    var body: some View {
        let marks = points
        if !marks.isEmpty {
            Chart(marks) { mark in
                if section.style == .bars {
                    BarMark(x: .value("Category", mark.category), y: .value("Count", mark.amount))
                        .foregroundStyle(Palette.indigo.gradient)
                        .cornerRadius(4)
                } else {
                    LineMark(x: .value("Period", mark.category), y: .value("Value", mark.amount))
                        .foregroundStyle(by: .value("Series", mark.series))
                        .symbol(by: .value("Series", mark.series))
                }
            }
            .chartForegroundStyleScale(range: [Palette.indigo, Palette.mint, Palette.peach, Palette.lavender])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7))
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 190)
            .padding(.vertical, 5)
            .accessibilityLabel(section.title)
        }
    }
}

private struct WeeklyChart: View {
    let rows: [[Cell]]
    private let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]

    var body: some View {
        let values = cells()
        let peak = max(1, values.max() ?? 1)
        ScrollView(.horizontal) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 24, height: 1)
                    ForEach(0..<24) { hour in
                        Text(hour % 3 == 0 ? String(hour) : "")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }
                }
                ForEach(days.indices, id: \.self) { day in
                    HStack(spacing: 4) {
                        Text(days[day])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        ForEach(0..<24) { hour in
                            let value = values[day*24+hour]
                            let label = "\(days[day]), \(hour):00 · \(value)"
                            RoundedRectangle(cornerRadius: 4)
                                .fill(value == 0 ? Palette.indigo.opacity(0.08) :
                                        Palette.indigo.opacity(0.19+0.81*Double(value)/Double(peak)))
                                .frame(width: 20, height: 20)
                                .help(label)
                                .accessibilityLabel(label)
                        }
                    }
                }
            }
            .padding(.bottom, 5)
        }
        Text("Lighter cells represent fewer records.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func cells() -> [Int64] {
        var values = Array(repeating: Int64(0), count: 168)
        for row in rows {
            guard let day = row[0].integer, let hour = row[1].integer,
                  (0..<7).contains(day), (0..<24).contains(hour) else { continue }
            values[Int(day*24+hour)] = row[2].integer ?? 0
        }
        return values
    }
}

private struct TokenCheck: View {
    let index: TokenIndex
    @State private var bundleID = ""
    @State private var token = ""

    var body: some View {
        Panel("Calculate App Token") {
            TextField("Bundle ID, such as com.apple.Notes", text: $bundleID)
                .textFieldStyle(.roundedBorder)
            let input = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !input.isEmpty {
                Text("lsBundleRecord:" + GraphReports.digest(input))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            Divider()
            TextField("Base64 token or prefixed reference",text:$token)
                .textFieldStyle(.roundedBorder)
            if !token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                if let found = index.words[TokenIndex.bare(token)] {
                    ForEach(found,id: \.self) { word in
                        Text(word).textSelection(.enabled)
                    }
                } else {
                    Text("No matches in the open graph.").foregroundStyle(.secondary)
                }
            }
        }
    }
}
