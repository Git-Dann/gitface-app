import SwiftUI

struct ContentView: View {

    @StateObject private var state = FaceTrackingState()
    @State private var showsDebugControls = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if state.isSupported {
                FaceARView(state: state)
                    .ignoresSafeArea()
            } else {
                unsupportedView
            }

            overlay
        }
        .task { state.startThermalTracking() }
        // Texture generation is async because `TextureResource` only offers
        // async constructors. A mask built before this lands gets the flat
        // material, so the current one is rebuilt once the cache is warm
        // rather than leaving the first-selected lens looking untextured.
        .task {
            await ProceduralTexture.warm()
            state.reapplyMask()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { state.errorMessage = nil } },
            message: { Text(state.errorMessage ?? "") }
        )
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            statusPill
                .padding(.top, 12)

            if state.isThermallyThrottled {
                thermalNotice
                    .padding(.top, 8)
            }

            Spacer()

            if state.isSupported {
                VStack(spacing: 18) {
                    if showsDebugControls { debugControls }

                    if let url = state.lastSavedURL, state.recording == .idle {
                        savedNotice(url: url)
                    }

                    EffectPicker(selection: $state.selectedWarp)

                    MaskCarousel(
                        selection: $state.selectedMask,
                        isEnabled: state.recording == .idle
                    )

                    RecordButton(
                        recording: state.recording,
                        progress: state.elapsed / state.maximumDuration,
                        isEnabled: state.canRecord,
                        action: state.toggleRecording
                    )
                }
                .padding(.bottom, 30)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            if state.recording == .recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(timecode)
                    .monospacedDigit()
            } else {
                Text(state.status.message)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .onTapGesture(count: 3) { showsDebugControls.toggle() }
    }

    private var thermalNotice: some View {
        Label("Running warm, recording at a lower frame rate", systemImage: "thermometer.high")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.75), in: Capsule())
    }

    private func savedNotice(url: URL) -> some View {
        HStack(spacing: 12) {
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))

            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Hidden behind a triple tap on the status pill. The tint spike is a
    /// diagnostic, not a feature, and comes out once M1 is settled.
    ///
    /// The sliders are here because every weight in `WarpStyle` is a guess
    /// until it is seen on a real face, and how old is old enough cannot be
    /// judged away from the device. Dial them in, read the numbers off the
    /// labels, and they get baked into the style.
    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Red tint spike", isOn: $state.isTintSpikeEnabled)

            tuningSlider("Warp", value: $state.tuning.warp, range: 0...2.5)
            tuningSlider("Creases", value: $state.tuning.crease, range: 0...2.5)
            tuningSlider("Ridges", value: $state.tuning.ridge, range: 0...2.5)
            tuningSlider("Sallow", value: $state.tuning.desaturate, range: 0...2.5)
            tuningSlider("Blotch", value: $state.tuning.blotch, range: 0...2.5)
            tuningSlider("Brows", value: $state.tuning.browGrey, range: 0...2)

            Button("Reset") { state.tuning = .neutral }
                .font(.caption.weight(.semibold))
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
    }

    private func tuningSlider(
        _ name: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .frame(width: 58, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .font(.caption2)
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "face.dashed")
                .font(.system(size: 52))
            Text("Face tracking isn't available")
                .font(.headline)
            Text("This device doesn't support ARKit face tracking.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    private var timecode: String {
        let total = Int(state.elapsed)
        return String(format: "%01d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView()
}
