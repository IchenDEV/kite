import SwiftUI

struct KiteMenuBarMark: View {
    var body: some View {
        KiteMenuBarMarkShape()
            .fill(.primary)
            .frame(width: 14, height: 14)
            .frame(width: 16, height: 16, alignment: .center)
            .accessibilityHidden(true)
    }
}

struct KiteMenuBarMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x * rect.width), y: rect.minY + (y * rect.height))
        }

        var path = Path()

        path.move(to: point(0.08, 0.06))
        path.addLine(to: point(0.32, 0.06))
        path.addLine(to: point(0.32, 0.94))
        path.addLine(to: point(0.08, 0.94))
        path.closeSubpath()

        path.move(to: point(0.29, 0.48))
        path.addLine(to: point(0.68, 0.06))
        path.addLine(to: point(0.94, 0.06))
        path.addLine(to: point(0.43, 0.60))
        path.closeSubpath()

        path.move(to: point(0.35, 0.43))
        path.addLine(to: point(0.73, 0.78))
        path.addLine(to: point(0.82, 0.69))
        path.addLine(to: point(0.94, 0.94))
        path.addLine(to: point(0.68, 0.85))
        path.addLine(to: point(0.77, 0.76))
        path.addLine(to: point(0.42, 0.54))
        path.closeSubpath()

        return path
    }
}
