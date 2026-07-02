import SwiftUI
import UIKit

struct LibraryCard: View {
    let item: LibraryItem
    let thumbnail: UIImage?

    var body: some View {
        Rectangle()
            .fill(SigmaTheme.surface)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Color.clear.overlay(alignment: .top) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
