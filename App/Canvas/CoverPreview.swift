import AutoGradeCore
import SwiftUI

/// The selected cover in the main view (CLAUDE.md 封面): the exported pixels,
/// fitted to the view, with the shape to preview and the output size.
struct CoverPreview: View {
    @Bindable var project: Project

    var body: some View {
        VStack(spacing: 8) {
            Picker(L(S.coverPreviewTitle), selection: $project.coverPreviewAspect) {
                ForEach(CoverAspect.allCases, id: \.self) { a in Text(coverAspectName(a)).tag(a) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .accessibilityLabel(L(S.coverPreviewTitle))
            ZStack {
                if let image = project.coverPreview {
                    let (w, h) = (Int(image.size.width), Int(image.size.height))
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel(L(S.coverPreviewLabel(w, h)))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let image = project.coverPreview {
                Text(L(S.coverPreviewSize(Int(image.size.width), Int(image.size.height))))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.black)
    }
}
