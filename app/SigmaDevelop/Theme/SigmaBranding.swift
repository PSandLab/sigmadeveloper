import SwiftUI

struct SigmaWordmark: View {
    var height: CGFloat = 17

    var body: some View {
        Image("SigmaWordmark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(SigmaTheme.ink)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("SIGMA")
    }
}

struct SigmaMark: View {
    var size: CGFloat = 60

    var body: some View {
        Image("SigmaMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(SigmaTheme.ink)
            .accessibilityLabel("SIGMA")
    }
}
