import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Wraps `UIActivityViewController` so developed files can be saved to Files,
/// shared, AirDropped, or added to Photos.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum ImportTypes {
    /// What the file importer will accept. `.x3f` has no system type, so we add a
    /// filename-extension type and lean on `public.data` as a catch-all; folders
    /// are allowed so a whole card/drive directory can be imported at once.
    static let content: [UTType] = {
        var types: [UTType] = [.folder, .image, .rawImage, .tiff, .data]
        if let x3f = UTType(filenameExtension: "x3f") { types.insert(x3f, at: 0) }
        return types
    }()
}
