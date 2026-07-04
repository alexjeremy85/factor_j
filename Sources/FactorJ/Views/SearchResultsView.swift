import FactorJCore
import SwiftUI

/// Resultados da busca full-text (RF-D3), agrupados por gravação.
/// Clique abre a gravação no timestamp do trecho.
struct SearchResultsView: View {
    @EnvironmentObject private var appState: AppState

    private var groupedHits: [(recordingId: Int64, title: String, hits: [AppDatabase.SearchHit])] {
        var order: [Int64] = []
        var groups: [Int64: (title: String, hits: [AppDatabase.SearchHit])] = [:]
        for hit in appState.searchHits {
            if groups[hit.recordingId] == nil {
                order.append(hit.recordingId)
                groups[hit.recordingId] = (hit.recordingTitle, [])
            }
            groups[hit.recordingId]?.hits.append(hit)
        }
        return order.compactMap { id in
            groups[id].map { (id, $0.title, $0.hits) }
        }
    }

    var body: some View {
        if appState.searchHits.isEmpty {
            ContentUnavailableView(
                "Nenhum resultado",
                systemImage: "magnifyingglass",
                description: Text("Nada encontrado para “\(appState.searchText)”.")
            )
        } else {
            List {
                ForEach(groupedHits, id: \.recordingId) { group in
                    Section(group.title) {
                        ForEach(group.hits) { hit in
                            Button {
                                appState.openSearchHit(hit)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(TimeFormat.display(ms: hit.startMs))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)
                                    Text(hit.snippet)
                                        .lineLimit(2)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
