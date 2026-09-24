import SwiftUI

struct RecordButton: View {

    var recording: FaceTrackingState.Recording
    var progress: Double
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 4)
                    .frame(width: 78, height: 78)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 78)

                shape
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || recording == .saving)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: recording)
    }

    @ViewBuilder
    private var shape: some View {
        switch recording {
        case .idle:
            Circle().fill(.red).frame(width: 62, height: 62)
        case .recording:
            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
        case .saving:
            ProgressView().tint(.white)
        }
    }
}
