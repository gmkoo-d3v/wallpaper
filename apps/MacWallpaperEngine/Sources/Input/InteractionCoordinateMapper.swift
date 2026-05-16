import CoreGraphics
import Foundation

struct InteractionCoordinateMapper {
    private let fitMode: RenderFitMode
    private let contentAspect: CGFloat

    init(fitMode: RenderFitMode, contentAspect: CGFloat) {
        self.fitMode = fitMode
        self.contentAspect = max(contentAspect, 0.0001)
    }

    func mapWindowNormalizedPoint(_ point: CGPoint, viewAspect: CGFloat) -> CGPoint? {
        let safeViewAspect = max(viewAspect, 0.0001)
        let point = CGPoint(
            x: min(max(point.x, 0.0), 1.0),
            y: min(max(point.y, 0.0), 1.0)
        )

        switch fitMode {
        case .contain:
            let rect = containedContentRect(viewAspect: safeViewAspect)
            guard rect.contains(point) else { return nil }
            return CGPoint(
                x: (point.x - rect.minX) / rect.width,
                y: (point.y - rect.minY) / rect.height
            )
        case .fill:
            if contentAspect > safeViewAspect {
                let visibleWidth = safeViewAspect / contentAspect
                let startX = (1.0 - visibleWidth) / 2.0
                return CGPoint(
                    x: startX + point.x * visibleWidth,
                    y: point.y
                )
            }

            let visibleHeight = contentAspect / safeViewAspect
            let startY = (1.0 - visibleHeight) / 2.0
            return CGPoint(
                x: point.x,
                y: startY + point.y * visibleHeight
            )
        }
    }

    func windowNormalizedPoint(forContentPoint point: CGPoint, viewAspect: CGFloat) -> CGPoint {
        let safeViewAspect = max(viewAspect, 0.0001)
        let point = CGPoint(
            x: min(max(point.x, 0.0), 1.0),
            y: min(max(point.y, 0.0), 1.0)
        )

        switch fitMode {
        case .contain:
            let rect = containedContentRect(viewAspect: safeViewAspect)
            return CGPoint(
                x: rect.minX + point.x * rect.width,
                y: rect.minY + point.y * rect.height
            )
        case .fill:
            if contentAspect > safeViewAspect {
                let visibleWidth = safeViewAspect / contentAspect
                let startX = (1.0 - visibleWidth) / 2.0
                return CGPoint(
                    x: (point.x - startX) / visibleWidth,
                    y: point.y
                )
            }

            let visibleHeight = contentAspect / safeViewAspect
            let startY = (1.0 - visibleHeight) / 2.0
            return CGPoint(
                x: point.x,
                y: (point.y - startY) / visibleHeight
            )
        }
    }

    private func containedContentRect(viewAspect: CGFloat) -> CGRect {
        if contentAspect > viewAspect {
            let height = viewAspect / contentAspect
            return CGRect(x: 0.0, y: (1.0 - height) / 2.0, width: 1.0, height: height)
        }

        let width = contentAspect / viewAspect
        return CGRect(x: (1.0 - width) / 2.0, y: 0.0, width: width, height: 1.0)
    }
}
