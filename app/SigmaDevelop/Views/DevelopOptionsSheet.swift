import SwiftUI

struct DevelopOptionsSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var entryKey: DevelopSettings.GlobalKey?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 4) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DevelopControls(settings: $store.defaults, isX3F: true)

                    Divider()

                    HStack {
                        Text("Default format")
                        Spacer()
                        Picker("Default format", selection: $store.defaults.exportFormat) {
                            ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .font(.body)
                    .padding(.vertical, 13)
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .foregroundStyle(SigmaTheme.ink)
        .tint(SigmaTheme.ink)
        .onAppear { entryKey = store.defaults.globalKey }
        .onDisappear {
            if store.defaults.globalKey != entryKey { store.applyGlobalDefaults() }
        }
        .presentationBackground(SigmaTheme.paper)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Develop")
                .font(.headline)
                .foregroundStyle(SigmaTheme.ink)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .tint(SigmaTheme.ink)
        }
    }
}
