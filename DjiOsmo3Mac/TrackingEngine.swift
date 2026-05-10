import Vision
import CoreMedia
import CoreImage
import CoreGraphics

// Processes camera frames with Vision and produces gimbal velocity commands.
// PID tuning constants are approximate starting points and may need adjustment
// for each physical gimbal + camera setup.
final class TrackingEngine {

    enum Target { case face, body }

    var target: Target = .face
    var isActive = false

    // Result delivered synchronously from process(sampleBuffer:).
    struct Output {
        let pitch: Double   // °/s — positive = up
        let yaw: Double     // °/s — positive = right
        let bounds: CGRect? // normalised [0..1] for the overlay
    }

    // PID state (separate integrators per axis).
    private var integralPitch: Double = 0
    private var integralYaw: Double = 0
    private var prevErrorPitch: Double = 0
    private var prevErrorYaw: Double = 0
    private var lastTime: Double = 0

    // PID gains — pitch / yaw
    private let kP: (Double, Double) = (80, 60)
    private let kI: (Double, Double) = (0.5, 0.3)
    private let kD: (Double, Double) = (15, 10)
    private let integralClamp: Double = 30   // °/s anti-windup

    // Vision requests (lazy so they are created once).
    private lazy var faceRequest = VNDetectFaceRectanglesRequest()
    private lazy var bodyRequest = VNDetectHumanBodyPoseRequest()
    private let ciContext = CIContext()

    // MARK: Public API

    func toggle() { isActive.toggle(); if !isActive { reset() } }

    func reset() {
        integralPitch = 0; integralYaw = 0
        prevErrorPitch = 0; prevErrorYaw = 0
        lastTime = 0
    }

    // Returns nil if tracking is inactive or no subject is found.
    func process(sampleBuffer: CMSampleBuffer) -> Output? {
        guard isActive else { return nil }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        let now = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let dt = lastTime == 0 ? (1.0 / 30.0) : max(0.001, now - lastTime)
        lastTime = now

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        var bounds: CGRect?

        switch target {
        case .face:
            try? handler.perform([faceRequest])
            if let obs = faceRequest.results?.first {
                bounds = obs.boundingBox
            }
        case .body:
            try? handler.perform([bodyRequest])
            if let obs = bodyRequest.results?.first {
                bounds = obs.boundingBox
            }
        }

        guard let box = bounds else { return Output(pitch: 0, yaw: 0, bounds: nil) }

        // Error = distance from frame centre to subject centre, normalised [-0.5..0.5].
        let subjectCX = box.midX - 0.5
        let subjectCY = box.midY - 0.5

        let yaw   = pid(error: subjectCX, integral: &integralYaw,   prevError: &prevErrorYaw,   kP: kP.1, kI: kI.1, kD: kD.1, dt: dt)
        let pitch = pid(error: -subjectCY, integral: &integralPitch, prevError: &prevErrorPitch, kP: kP.0, kI: kI.0, kD: kD.0, dt: dt)

        return Output(pitch: pitch, yaw: yaw, bounds: box)
    }

    // MARK: PID

    private func pid(error: Double,
                     integral: inout Double,
                     prevError: inout Double,
                     kP: Double, kI: Double, kD: Double,
                     dt: Double) -> Double {
        integral = (integral + error * dt).clamped(-integralClamp / kI, integralClamp / kI)
        let derivative = (error - prevError) / dt
        prevError = error
        let output = kP * error + kI * integral + kD * derivative
        return output.clamped(-integralClamp * 4, integralClamp * 4)
    }
}

