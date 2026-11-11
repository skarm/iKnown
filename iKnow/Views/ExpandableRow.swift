import SwiftUI

struct ExpandableRow<Header: View, Content: View>: View {
    private let header: Header
    private let content: () -> Content
    @State private var expanded = false

    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Header) {
        self.header = label()
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 34)
                        .accessibilityHidden(true)
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(.interaction, Rectangle())
                .textSelection(.disabled)
            }
            .buttonStyle(ExpandableHeaderButtonStyle())
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                content()
            }
        }
    }
}

extension ExpandableRow where Header == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

private struct ExpandableHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Header(configuration: configuration)
    }

    private struct Header: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .contentShape(.interaction, Rectangle())
                .background(.primary.opacity(configuration.isPressed ? 0.10 : (hovered ? 0.045 : 0)),
                            in: .rect(cornerRadius: 7))
                .onHover { hovered = $0 }
        }
    }
}
