import SwiftUI
import AppKit

struct CatalogIconView: View {
    let icon: String?
    let fallback: String
    let color: Color
    var body: some View {
        Self.image(icon, fallback: fallback).foregroundStyle(color).frame(width: 16, height: 16)
    }
    static func image(_ icon: String?, fallback: String) -> Image {
        if icon == SessionIcon.kubernetes.rawValue { return Image(nsImage: kubernetesImage) }
        if icon == SessionIcon.server.rawValue { return Image(systemName: "server.rack") }
        if icon == SessionIcon.network.rawValue { return Image(nsImage: switchImage) }
        return Image(systemName: icon.flatMap { SessionIcon(rawValue: $0) }?.rawValue ?? fallback)
    }
    private static func template(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            draw(context)
            return true
        }
        image.isTemplate = true
        return image
    }
    private static let switchImage = template { context in
        context.translateBy(x: 1.35, y: 1.35)
        context.scaleBy(x: 0.85, y: 0.85)
        let body = CGPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.addPath(body)
        context.setLineWidth(1.25)
        context.strokePath()
        context.setLineWidth(1.05)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for y: CGFloat in [6, 12] {
            for direction: CGFloat in [-1, 1] {
                let center: CGFloat = 9 + direction * 1.2
                let tip = 9 + direction * 5.4
                context.move(to: CGPoint(x: center, y: y))
                context.addLine(to: CGPoint(x: tip, y: y))
                context.move(to: CGPoint(x: tip - direction * 1.6, y: y + 1.5))
                context.addLine(to: CGPoint(x: tip, y: y))
                context.addLine(to: CGPoint(x: tip - direction * 1.6, y: y - 1.5))
                context.strokePath()
            }
        }
    }
    private static let kubernetesImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(KubernetesIcon().path(in: rect.insetBy(dx: 1.35, dy: 1.35)).cgPath)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.65)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()

}

struct SessionProfileIcon: View {
    let profile: SessionProfile
    var body: some View {
        CatalogIconView(icon: profile.icon, fallback: profile.connectionType.icon,
            color: profile.color == nil && profile.connectionType == .ssh ? .cyan : sessionColor(profile.color))
    }
}

struct FolderIconView: View {
    let icon: String?
    let color: Color
    var body: some View { Image(systemName: "folder.fill").foregroundStyle(color).frame(width: 16, height: 16) }
}

private struct KubernetesIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius * scale, y: center.y + sin(angle) * radius * scale)
        }
        var path = Path()
        for i in 0..<7 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 7
            let outer = point(7.25, angle)
            if i == 0 { path.move(to: outer) } else { path.addLine(to: outer) }
        }
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: center.x - 2.3 * scale, y: center.y - 2.3 * scale,
                                   width: 4.6 * scale, height: 4.6 * scale))
        for i in 0..<7 {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 7
            path.move(to: point(2.3, angle))
            path.addLine(to: point(5.25, angle))
        }
        return path
    }
}
