import SwiftUI

struct SectionGlyph: View {
    let icon: SectionIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .system(let symbol):
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
        case .familyTree:
            FamilyTree()
                .stroke(style: StrokeStyle(lineWidth: size / 12, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
    }
}

private struct FamilyTree: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * unit, y: rect.midY - 8 * unit)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }

        var path = Path()
        for (x, y) in [(6.0, 1.0), (1.0, 11.0), (11.0, 11.0)] {
            let node = CGRect(origin: point(x, y), size: CGSize(width: 4 * unit, height: 4 * unit))
            path.addRoundedRect(in: node, cornerSize: CGSize(width: unit, height: unit))
        }
        path.move(to: point(8, 5))
        path.addLine(to: point(8, 8))
        path.move(to: point(3, 11))
        path.addLine(to: point(3, 8))
        path.addLine(to: point(13, 8))
        path.addLine(to: point(13, 11))
        return path
    }
}
