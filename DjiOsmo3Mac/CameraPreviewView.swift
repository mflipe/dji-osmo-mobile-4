import SwiftUI
import AVFoundation

// NSViewRepresentable that hosts an AVCaptureVideoPreviewLayer.
// Resizes its layer to match the view bounds automatically.
struct CameraPreviewView: NSViewRepresentable {
    let cameraManager: CameraManager
    // Optional bounding-box rect in normalised coordinates [0..1] from TrackingEngine.
    var trackingBounds: CGRect?

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer = cameraManager.makePreviewLayer()
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.trackingBounds = trackingBounds
        nsView.setNeedsDisplay(nsView.bounds)
    }
}

// MARK: - PreviewNSView

final class PreviewNSView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard let layer = previewLayer else { return }
            wantsLayer = true
            self.layer?.addSublayer(layer)
            layer.frame = bounds
        }
    }

    var trackingBounds: CGRect?   // normalised, nil = no overlay

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let bounds = trackingBounds, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Convert normalised [0..1] rect to view coordinates (origin bottom-left in Core Graphics).
        let vw = self.bounds.width
        let vh = self.bounds.height
        let rect = CGRect(
            x: bounds.minX * vw,
            y: (1 - bounds.maxY) * vh,
            width: bounds.width * vw,
            height: bounds.height * vh
        )

        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect)

        // Crosshair at centre.
        let cx = rect.midX, cy = rect.midY
        let arm: CGFloat = 10
        ctx.move(to: CGPoint(x: cx - arm, y: cy))
        ctx.addLine(to: CGPoint(x: cx + arm, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - arm))
        ctx.addLine(to: CGPoint(x: cx, y: cy + arm))
        ctx.strokePath()
    }
}
