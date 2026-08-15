// CameraPreview.swift
//
// SwiftUI wrapper around AVCaptureVideoPreviewLayer showing the live camera
// image. videoGravity = .resizeAspectFill covers the whole screen and crops the
// overhang -- the same layout AspectFit assumes -- so overlays drawn on top
// align with the image.

import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        // Fill the screen: the camera image covers the whole display and the
        // overhang is cropped. AspectFit does the same, and they must agree -
        // it is how a detection in buffer pixels becomes a box on screen, so a
        // filling preview with a fitting overlay draws everything at the wrong
        // scale and offset.
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.applyRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Pin the preview to the same rotation the capture output uses.
        ///
        /// Applied from `layoutSubviews`, and that is the whole point. The
        /// layer's `connection` DOES NOT EXIST yet when the view is created, so
        /// setting the angle there does nothing at all - it just falls out of
        /// the `guard`. Previously the only other chance was `updateUIView`,
        /// which SwiftUI runs when the view's inputs change; once the angle
        /// became a constant, nothing ever changed, so it never ran again and
        /// the layer kept its 90-degree portrait default. That is why a rotate
        /// BUTTON appeared to fix the orientation while a fixed value did not:
        /// tapping it changed an input and forced the update through.
        ///
        /// layoutSubviews runs after the layer is attached and on every bounds
        /// change, and the assignment is idempotent, so the rotation is applied
        /// as soon as it can be and stays applied.
        func applyRotation() {
            guard let conn = videoPreviewLayer.connection else { return }
            CameraManager.apply(CameraManager.landscapeAngle, to: conn)
            // Never mirror, front camera included. The capture buffers are
            // deliberately unmirrored (see CameraManager.configure) so the
            // court's left stays left; a preview that auto-mirrors while the
            // buffers don't would draw every overlay x-flipped. Looks unlike a
            // selfie, and that is correct - this is a court monitor.
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyRotation()
        }
    }
}
