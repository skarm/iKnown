import SwiftUI

struct WorkspaceView: View {
    let source: GraphSource
    let revision: Int
    let masked: Bool
    let target: GraphTarget?
    let onSelect: (GraphTarget) -> Void
    @FocusState private var searchFocused: Bool
    @State private var layer: GraphLayer = .stable
    @State private var search = ""
    @State private var page = 0
    @State private var catalog: Catalog?
    @State private var detail: GraphDetail?
    @State private var selectedID: Int64?
    @State private var selectedNeighbor: Int64?
    @State private var catalogError: GraphFailure?
    @State private var detailError: String?
    @State private var showingInspector = true
    @State private var loadingCatalog = true
    @State private var loadingDetail = false

    private struct CatalogRequest: Equatable {
        let source: GraphSource
        let layer: GraphLayer
        let search: String
        let page: Int
        let revision: Int
    }

    private struct DetailRequest: Equatable {
        let source: GraphSource
        let layer: GraphLayer
        let id: Int64?
        let revision: Int
    }

    private var catalogRequest: CatalogRequest {
        CatalogRequest(source: source, layer: layer, search: search, page: page, revision: revision)
    }

    private var detailRequest: DetailRequest {
        DetailRequest(source: source, layer: layer, id: selectedID, revision: revision)
    }

    var body: some View {
        let catalogRequest = self.catalogRequest
        let detailRequest = self.detailRequest
        HSplitView {
            catalogBrowser
                .frame(minWidth: 184, idealWidth: 218, maxWidth: 270, maxHeight: .infinity)
            graph
                .frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.secondary)
        }
        .inspector(isPresented: $showingInspector) {
            inspector
                .inspectorColumnWidth(min: 226, ideal: 282, max: 430)
        }
        .onChange(of: masked) {
            if masked {
                updateSearch("")
                searchFocused = false
            }
        }
        .onChange(of: target, initial: true) {
            guard let target else { return }
            changeLayer(target.layer)
            selectEntity(target.id)
        }
        .task(id: catalogRequest) { await loadCatalog(catalogRequest) }
        .task(id: detailRequest) { await loadDetail(detailRequest) }
    }

    private var catalogBrowser: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Entities")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                searchField
                if let catalog {
                    Menu {
                        ForEach(catalog.layers) { item in
                            Button { changeLayer(item) } label: {
                                if item == layer {
                                    Label(item.title, systemImage: "checkmark")
                                } else {
                                    Text(item.title)
                                }
                            }
                        }
                    } label: {
                        Label(layer.title, systemImage: layer.symbol)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Graph Layer")
                    .accessibilityValue(layer.title)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 17)
            .padding(.bottom, 10)
            Divider().padding(.horizontal, 12)
            catalogResults
        }
        .background(.background)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Button("Find an Entity", systemImage: "magnifyingglass") { searchFocused = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .keyboardShortcut("f")
                .foregroundStyle(.secondary)
            TextField("Name, address, or ID", text: Binding(get: { search }, set: updateSearch))
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .accessibilityLabel("Search Entities")
            if !search.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { updateSearch("") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.indigo.opacity(searchFocused ? 0.72 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .disabled(masked)
        .help(masked ? "Search is available while personal data is visible" : "Search the current layer")
    }

    @ViewBuilder private var catalogResults: some View {
        if let catalog, catalog.layer == layer {
            if catalog.entities.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No Entities" : "No Matches",
                          systemImage: search.isEmpty ? "tray" : "magnifyingglass")
                } actions: {
                    if !search.isEmpty {
                        Button("Clear Search") { updateSearch("") }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { selectedID }, set: selectEntity)) {
                    ForEach(Array(catalog.entities.enumerated()), id: \.element.id) { index, entity in
                        let name = masked ? "Entity \(page * Catalog.pageSize + index + 1)" : entity.name
                        EntityListRow(entity: entity, name: name)
                            .tag(entity.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(.init(top: 1, leading: 10, bottom: 1, trailing: 10))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Graph Entities")
            }
            pagination(catalog)
        } else {
            Spacer()
            if loadingCatalog {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    private func pagination(_ catalog: Catalog) -> some View {
        let start = page * Catalog.pageSize + 1
        let end = start + catalog.entities.count - 1
        return HStack(spacing: 9) {
            if loadingCatalog {
                ProgressView().controlSize(.mini)
            }
            Text(catalog.entities.isEmpty ? "0 results" : "Records \(start)–\(end)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if page > 0 || catalog.hasNextPage {
                Button("Previous Page", systemImage: "chevron.left") { changePage(page - 1) }
                    .disabled(page == 0 || loadingCatalog)
                Button("Next Page", systemImage: "chevron.right") { changePage(page + 1) }
                    .disabled(!catalog.hasNextPage || loadingCatalog)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
    }

    @ViewBuilder private var graph: some View {
        if let catalogError {
            DatabaseFailureView(failure: catalogError, source: source)
        } else if let detail {
            GraphView(detail: detail, layer: layer, selection: selectedNeighbor, masked: masked,
                      showingInspector: $showingInspector) { id in
                selectedNeighbor = id
                showingInspector = true
            }
            .padding(17)
        } else if let detailError {
            ContentUnavailableView(detailError, systemImage: "exclamationmark.circle")
        } else if loadingCatalog || loadingDetail || selectedID != nil {
            ProgressView("Loading graph…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select an Entity", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    @ViewBuilder private var inspector: some View {
        if let detail {
            EvidenceInspector(
                detail: detail,
                connection: detail.connections.first { $0.id == selectedNeighbor },
                masked: masked,
                showEntity: { selectedNeighbor = nil },
                selectConnection: { selectedNeighbor = $0.id },
                openConnection: { connection in
                    guard let target = connection.layer else { return }
                    if layer != target { changeLayer(target) }
                    selectEntity(connection.id)
                }
            )
        } else {
            ContentUnavailableView("No Record Selected", systemImage: "sidebar.right")
        }
    }

    private func changeLayer(_ next: GraphLayer) {
        guard layer != next else { return }
        layer = next
        page = 0
        selectEntity(nil)
    }

    private func changePage(_ next: Int) {
        page = next
        selectEntity(nil)
    }

    private func updateSearch(_ query: String) {
        guard search != query else { return }
        search = query
        page = 0
    }

    private func selectEntity(_ id: Int64?) {
        guard selectedID != id else { return }
        selectedID = id
        selectedNeighbor = nil
        detail = nil
        detailError = nil
        loadingDetail = id != nil
    }

    private func loadCatalog(_ request: CatalogRequest) async {
        guard !Task.isCancelled, request == catalogRequest else { return }
        loadingCatalog = true
        defer { if !Task.isCancelled, request == catalogRequest { loadingCatalog = false } }
        do {
            if !request.search.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
            let result = try await GraphRepository.catalog(
                source: request.source, requestedLayer: request.layer, search: request.search, page: request.page
            )
            guard !Task.isCancelled, request == catalogRequest else { return }
            catalogError = nil
            catalog = result
            if result.layer != layer { changeLayer(result.layer) }
            let searching = !request.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let containsSelection = result.entities.contains { $0.id == selectedID }
            if selectedID == nil || (searching && !containsSelection) {
                selectEntity(result.entities.first?.id)
            }
        } catch {
            guard !Task.isCancelled, request == catalogRequest else { return }
            catalog = nil
            selectEntity(nil)
            catalogError = (error as? GraphFailure) ?? .unreadable
        }
    }

    private func loadDetail(_ request: DetailRequest) async {
        guard let id = request.id, !Task.isCancelled, request == detailRequest else { return }
        loadingDetail = true
        defer { if !Task.isCancelled, request == detailRequest { loadingDetail = false } }
        do {
            let result = try await GraphRepository.detail(source: request.source, layer: request.layer, id: id)
            guard !Task.isCancelled, request == detailRequest else { return }
            detail = result
            detailError = result == nil ? "Entity Not Found in This Layer" : nil
            if result != nil { onSelect(GraphTarget(id: id, layer: request.layer)) }
            if result?.connections.contains(where: { $0.id == selectedNeighbor }) != true {
                selectedNeighbor = nil
            }
        } catch {
            guard !Task.isCancelled, request == detailRequest else { return }
            detail = nil
            detailError = error.localizedDescription
        }
    }
}

struct EntityGlyph: View {
    let entity: Entity?
    var size: CGFloat = 29

    var body: some View {
        let tint = Palette.entityTint(entity)
        Image(systemName: entity?.symbol ?? "circle.dotted")
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: .rect(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

private struct EntityListRow: View {
    let entity: Entity
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            EntityGlyph(entity: entity)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Text(entity.isOwner ? "Mac Owner" : entity.kind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .help(name)
    }
}
