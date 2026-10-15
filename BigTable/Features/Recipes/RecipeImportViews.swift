import Foundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

/// Which import screen is up (the scanner or the camera), and the photo being
/// imported. Lives with the editor so the sheets sit outside the form's lazy rows.
@MainActor
@Observable
final class RecipeImportFlow {
    var showScanner = false
    var showScanCamera = false
    var photoItem: PhotosPickerItem?
}

/// Presents the scanner and camera for New Recipe, and reads the pages or photo they return
/// (on the device when it can).
struct RecipeImportPresenter: ViewModifier {
    var model: RecipeEditorModel
    @Bindable var flow: RecipeImportFlow
    var onNotice: (RecipeEditorNotice) -> Void
    /// The scan filled in the recipe.
    var onFilled: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $flow.showScanner) {
                RecipeDocumentScanner { images in
                    flow.showScanner = false
                    scan(images)
                } onCancel: {
                    flow.showScanner = false
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $flow.showScanCamera) {
                CameraPicker { image in
                    scan([image])
                }
                .ignoresSafeArea()
            }
            .onChange(of: flow.photoItem) {
                guard let item = flow.photoItem else { return }
                flow.photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        onNotice(RecipeEditorNotice(title: "Couldn't open that photo", message: "Try a different photo or screenshot."))
                        return
                    }
                    scan([image])
                }
            }
    }

    private func scan(_ images: [UIImage]) {
        let jpegs = RecipeScanImages.build(from: images)
        guard !jpegs.isEmpty else {
            onNotice(RecipeEditorNotice(title: "Couldn't read that image", message: "Try again with a clearer photo."))
            return
        }
        Task {
            do {
                let outcome = try await model.scan(jpegs)
                switch outcome {
                case .filled:
                    onFilled()
                case .notRecipe(let reason):
                    onNotice(RecipeEditorNotice(title: "No recipe found", message: reason))
                case .nothingFound:
                    onNotice(RecipeEditorNotice(title: "No recipe found", message: "Try again with better light and the whole recipe in view."))
                }
            } catch {
                onNotice(.failure(error, title: "Couldn't read the recipe"))
            }
        }
    }
}

/// VisionKit's document camera: scans one or more pages, flattened and cropped.
struct RecipeDocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: RecipeDocumentScanner
        init(_ parent: RecipeDocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}

/// Images for /v1/bigtable/ai/recipe-scan, as the Expo app sent them: each page as a JPEG no larger
/// than 1536 points, and very tall screenshots sliced into bands so the text stays legible.
/// At most 8 images (the API's limit).
enum RecipeScanImages {
    static func build(from images: [UIImage]) -> [Data] {
        var result: [Data] = []
        for image in images {
            result.append(contentsOf: encode(image))
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    private static func encode(_ image: UIImage) -> [Data] {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return [] }
        guard size.height / size.width >= 2.4 else {
            return PhotoTools.jpeg(from: image, maxSide: 1536, quality: 0.82).map { [$0] } ?? []
        }
        // A tall screenshot: up to six bands, each about 1100 wide.
        let targetWidth = min(size.width, 1100)
        let scaledHeight = size.height * targetWidth / size.width
        let bandCount = min(6, max(2, Int((scaledHeight / 1280).rounded(.up))))
        let bandHeight = (size.height / CGFloat(bandCount)).rounded(.up)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var bands: [Data] = []
        for index in 0..<bandCount {
            let originY = CGFloat(index) * bandHeight
            guard originY < size.height else { break }
            let height = min(bandHeight, size.height - originY)
            let scale = targetWidth / size.width
            let outSize = CGSize(width: targetWidth, height: (height * scale).rounded())
            let band = UIGraphicsImageRenderer(size: outSize, format: format).image { _ in
                image.draw(in: CGRect(x: 0, y: -originY * scale, width: targetWidth, height: size.height * scale))
            }
            if let data = band.jpegData(compressionQuality: 0.82) { bands.append(data) }
        }
        return bands
    }
}

/// Recipe photos are square, 1280 points, as the Expo app cropped them.
enum RecipePhotoCrop {
    static func square(_ image: UIImage, side: CGFloat = 1280, quality: CGFloat = 0.86) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let crop = min(size.width, size.height)
        let target = min(side, crop)
        let scale = target / crop
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
