import SwiftUI
import UIKit

// MARK: - Camera capture (iOS-only addition, §D row 46)

/// `UIImagePickerController(.camera)` for photographing food, packaging, labels or health screens.
/// Present it with `.fullScreenCover`; it dismisses itself. Falls back to the photo library where there is no camera
/// (Simulator). Requires `NSCameraUsageDescription` (present in Info.plist).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: @MainActor (UIImage) -> Void

    init(onImage: @escaping @MainActor (UIImage) -> Void) { self.onImage = onImage }

    static var isCameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = Self.isCameraAvailable ? .camera : .photoLibrary
        picker.mediaTypes = ["public.image"]
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        context.coordinator.dismiss = context.environment.dismiss
        return picker
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {
        context.coordinator.onImage = onImage
        context.coordinator.dismiss = context.environment.dismiss
    }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onImage: @MainActor (UIImage) -> Void
        var dismiss: DismissAction?

        init(onImage: @escaping @MainActor (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            close(picker)
            if let image { onImage(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { close(picker) }

        private func close(_ picker: UIImagePickerController) {
            if let dismiss { dismiss() } else { picker.dismiss(animated: true) }
        }
    }
}
