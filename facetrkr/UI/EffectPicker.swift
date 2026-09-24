import SwiftUI

struct EffectPicker: View {

    @Binding var selection: WarpStyle

    var body: some View {
        HStack(spacing: 10) {
            ForEach(WarpStyle.all) { effect in
                Button {
                    selection = effect
                } label: {
                    Label(effect.name, systemImage: effect.symbol)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(
                                effect.id == selection.id
                                    ? AnyShapeStyle(.white.opacity(0.9))
                                    : AnyShapeStyle(.ultraThinMaterial)
                            )
                        )
                        .foregroundStyle(effect.id == selection.id ? .black : .white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(effect.name)
            }
        }
    }
}
