import SwiftUI
import AVFoundation

// Wraps an AVCaptureVideoPreviewLayer in a SwiftUI view.
// Accepts an AVCaptureSession directly — not coupled to CameraManager.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var trackingBounds: CGRect?

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.previewLayer = layer
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

    var trackingBounds: CGRect?

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let bounds = trackingBounds,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let vw = self.bounds.width, vh = self.bounds.height
        let rect = CGRect(x: bounds.minX * vw, y: (1 - bounds.maxY) * vh,
                          width: bounds.width * vw, height: bounds.height * vh)
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect)
        let cx = rect.midX, cy = rect.midY, arm: CGFloat = 10
        ctx.move(to: CGPoint(x: cx - arm, y: cy)); ctx.addLine(to: CGPoint(x: cx + arm, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - arm)); ctx.addLine(to: CGPoint(x: cx, y: cy + arm))
        ctx.strokePath()
    }
}
