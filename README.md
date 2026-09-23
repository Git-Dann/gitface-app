# facetrkr

Face-tracked 3D masks and distortion effects on iPhone, recorded to video.

Native ARKit + RealityKit. No third-party AR SDK.

## Why it's built this way

RealityKit's post-process render callback hands you the **already-composited**
frame — camera passthrough *and* rendered 3D content — as an `MTLTexture`, plus a
live command buffer:

```swift
arView.renderCallbacks.postProcess = { context in
    // context.sourceColorTexture  — the finished frame
    // context.targetColorTexture  — what reaches the screen (you MUST write this)
    // context.sourceDepthTexture, context.commandBuffer, context.device
}
```

That one hook serves all three features:

| Feature | How |
|---|---|
| 3D props | Rendered by RealityKit before the callback. Nothing special. |
| Distortion | A Metal warp shader on `sourceColorTexture`, driven by face landmarks. |
| Recording | Blit the same texture into a pooled `CVPixelBuffer` → `AVAssetWriter`. |

So we never composite camera and 3D ourselves, never touch YCbCr conversion, and
never fight `displayTransform`. The texture arrives in display orientation.

Two notes on the surrounding tech, both counterintuitive in 2026:

- **SceneKit was soft-deprecated at WWDC25** (session 288). Nearly every face-AR
  tutorial online uses `ARSCNFaceGeometry`. Ignore them.
- **`ARView`, not `RealityView`.** Blendshape coefficients only arrive via
  `ARSessionDelegate`, and `ARView` exposes `.session` directly.

## Setup

The Xcode project is created locally and committed; the agent working on this repo
runs on Linux and fills in sources.

1. Clone and check out the working branch:

   ```bash
   git clone https://github.com/Git-Dann/gitface-app ~/Developer/gitface-app
   cd ~/Developer/gitface-app
   git checkout claude/gifted-allen-fkkh38
   ```

2. Move the Xcode project in from wherever you created it. If it's still in
   Xcode's scratch area, get it out of there — that directory is disposable:

   ```bash
   mv "/Users/daniellindsay/Library/Developer/Xcode/UntitledProjects/Untitled Project/"* .
   ```

3. Open `facetrkr.xcodeproj` and confirm:
   - Deployment target **iOS 18.0**
   - Interface **SwiftUI**
   - The app target uses a **file-system-synchronized folder** — a blue folder
     icon, not a yellow group. Xcode 16+ does this by default and it means new
     source files appear in the target with no project-file edits. If it's a
     yellow group, say so; files will need dragging in manually.

4. Add the camera purpose string. In **Build Settings → Info.plist Values**, set
   `Privacy - Camera Usage Description` to something specific:

   > Used to show 3D masks on your face in the live camera view and to record videos.

   Vague purpose strings are a routine App Review rejection, and specific ones are
   better for users regardless. Microphone and photo library strings come in M3.

5. Replace the body of `ContentView.swift` with:

   ```swift
   import SwiftUI

   struct ContentView: View {
       @StateObject private var state = FaceTrackingState()

       var body: some View {
           ZStack(alignment: .bottom) {
               FaceARView(state: state)
                   .ignoresSafeArea()

               VStack(spacing: 12) {
                   Text(state.status.message)
                       .font(.callout.weight(.medium))
                       .padding(.horizontal, 14)
                       .padding(.vertical, 8)
                       .background(.thinMaterial, in: Capsule())

                   Toggle("Red tint spike", isOn: $state.isTintSpikeEnabled)
                       .padding(.horizontal, 40)
               }
               .padding(.bottom, 40)
           }
       }
   }
   ```

6. Build and run **on the device**. The Simulator cannot do face tracking.

## M1 acceptance

- Camera permission prompts once, with your purpose string.
- A pink cube sits at your nose tip and tracks head rotation and translation.
- The console logs the supported face-tracking video formats. Note them — the only
  public data point is 720p-only and it dates from 2018.
- **The spike:** flip "Red tint spike" on.
  - Camera feed turns red → `sourceColorTexture` includes passthrough. The
    recording architecture holds and M2/M3 proceed as planned.
  - Only the cube turns red → passthrough is not included. Recording has to
    composite `ARFrame.capturedImage` manually and gets meaningfully harder.

  This claim is inferred from a WWDC21 example rather than documented, which is
  why it's checked before anything is built on top of it.
- Backgrounding and returning doesn't kill the session.

## Roadmap

| Milestone | Scope |
|---|---|
| M1 | Face tracking, nose marker, passthrough spike ← **here** |
| M2 | Procedural props, face occlusion mesh, mask carousel |
| M3 | Frame tap, `AVAssetWriter`, save to camera roll, share |
| M4 | Distortion shaders (bulge eyes, stretch jaw, big head) |
| M5 | Thermal governor, clip cap, expression-triggered effects |

## Privacy

All face data stays on device. Blendshape coefficients, face meshes and landmarks
are never transmitted or logged. Recorded video is user content that only goes
where the user sends it.

Note this is face *tracking*, not Face ID. Face ID biometrics are never accessible
to apps — `LocalAuthentication` returns pass/fail only. The two are unrelated, and
the term "Face ID" is deliberately absent from the UI and metadata.
