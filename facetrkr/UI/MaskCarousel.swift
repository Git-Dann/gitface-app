import SwiftUI

struct MaskCarousel: View {

    @Binding var selection: Mask
    var isEnabled: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(MaskLibrary.all) { mask in
                    Button {
                        selection = mask
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: mask.symbol)
                                .font(.system(size: 22))
                                .frame(width: 56, height: 56)
                                .background(
                                    Circle().fill(
                                        mask.id == selection.id
                                            ? AnyShapeStyle(.tint)
                                            : AnyShapeStyle(.ultraThinMaterial)
                                    )
                                )
                                .overlay(
                                    Circle().strokeBorder(
                                        .white.opacity(mask.id == selection.id ? 0.9 : 0.25),
                                        lineWidth: 1.5
                                    )
                                )

                            Text(mask.name)
                                .font(.caption2)
                                .opacity(mask.id == selection.id ? 1 : 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 24)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
