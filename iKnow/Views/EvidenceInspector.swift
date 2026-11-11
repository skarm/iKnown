import SwiftUI

struct EvidenceInspector: View {
    let detail: GraphDetail
    let connection: Connection?
    let masked: Bool
    let showEntity: () -> Void
    let selectConnection: (Connection) -> Void
    let openConnection: (Connection) -> Void

    private enum Tab: Hashable { case records, connections }
    @State private var tab: Tab = .records

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let connection {
                        connectionEvidence(connection)
                    } else if tab == .connections {
                        connections
                    } else {
                        statements
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(connection?.id ?? detail.entity.id)
        }
        .background(.background)
        .onChange(of: detail.entity.id) { tab = .records }
    }

    private var header: some View {
        let entity = connection == nil ? detail.entity : connection?.entity
        let name = connection?.name ?? detail.entity.name
        return VStack(alignment: .leading, spacing: 10) {
            if connection != nil {
                Button("Back to Entity Records", systemImage: "chevron.left", action: showEntity)
                    .buttonStyle(.link)
                    .font(.caption.weight(.medium))
            }
            HStack(alignment: .top, spacing: 9) {
                EntityGlyph(entity: entity, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(masked ? "Selected Entity" : name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let entity {
                        Text(entity.isOwner ? "Mac Owner" : entity.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if !masked {
                Text("ID \(String(connection?.id ?? detail.entity.id))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let connection {
                if connection.layer != nil {
                    Button("Open Entity", systemImage: "arrow.up.right") { openConnection(connection) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Text("No entity for this reference was found in the available layers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Inspector Section", selection: $tab) {
                    Text("Records \(detail.statements.count)").tag(Tab.records)
                    Text("Connections \(detail.connections.count)").tag(Tab.connections)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(13)
    }

    @ViewBuilder private var connections: some View {
        if detail.connections.isEmpty {
            Label("No direct connections", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(Array(detail.connections.enumerated()), id: \.element.id) { index, item in
            let name = masked ? "Connection \(index + 1)" : item.name
            Button { selectConnection(item) } label: {
                HStack(spacing: 8) {
                    EntityGlyph(entity: item.entity, size: 25)
                    Text(name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text((item.incoming.count + item.outgoing.count).formatted(.number.locale(.iKnow)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(7)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(name)
        }
        if detail.hasMoreConnections {
            Text("Showing the first \(detail.connections.count) connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statements: some View {
        if detail.statements.isEmpty {
            Label("No Records", systemImage: "text.alignleft")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(detail.statements) { statement in
            ExpandableRow {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(statement.rows) { row in
                        EvidenceRow(row: row, masked: masked)
                    }
                }
                .padding(.top, 7)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statement.label)
                        .font(.callout.weight(.medium))
                    if statement.rows.count == 1 {
                        Text(masked ? "Hidden" : (statement.rows.first?.value ?? "NULL"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(statement.rows.count) records")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.bottom, 3)
            Divider()
        }
        if detail.hasMoreStatements {
            Text("Showing the first 2,000 rows for this entity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func connectionEvidence(_ connection: Connection) -> some View {
        if !connection.outgoing.isEmpty {
            evidenceSection("Outgoing Records", symbol: "arrow.up.right", rows: connection.outgoing)
        }
        if !connection.incoming.isEmpty {
            evidenceSection("Incoming Records", symbol: "arrow.down.left", rows: connection.incoming)
        }
    }

    private func evidenceSection(_ title: String, symbol: String, rows: [Evidence]) -> some View {
        Section {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.predicateLabel)
                        .font(.callout.weight(.medium))
                    EvidenceRow(row: row, masked: masked)
                }
            }
        } header: {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct EvidenceRow: View {
    let row: Evidence
    let masked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let facet = row.facetLabel {
                Text(facet).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(masked ? "Hidden" : (row.value ?? "NULL"))
                .font(.callout.monospaced())
                .lineLimit(8)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 5) {
                field("Predicate", row.predicate)
                if let facet = row.facet { field("Field", facet) }
                if !masked && row.relationshipID != 0 { field("Relationship ID", String(row.relationshipID)) }
                if let confidence = row.confidence {
                    field("Confidence", confidence.formatted(.number.locale(.iKnow).precision(.fractionLength(0...4))))
                }
                if let sources = row.sources { field("Mask", "0x" + String(UInt64(bitPattern: sources), radix: 16)) }
                if !row.sourceLabels.isEmpty { field("Sources", row.sourceLabels.joined(separator: ", ")) }
                if let date = row.writtenAt {
                    field("Recorded", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: .iKnow)))
                }
            }
            .font(.caption)
            .textSelection(.enabled)
            if !masked && !row.sourceRecords.isEmpty {
                ExpandableRow("Source Records (\(row.sourceRecords.count))") {
                    Text(row.sourceRecords.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .padding(.top, 3)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 71, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
