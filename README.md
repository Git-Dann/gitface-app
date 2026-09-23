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

The Xcode project is generated and committed, so there is nothing to assemble.

```bash
git clone https://github.com/Git-Dann/gitface-app ~/Developer/gitface-app
cd ~/Developer/gitface-app
git checkout claude/gifted-allen-fkkh38
open facetrkr.xcodeproj
```

Set your signing team under **Signing & Capabilities**, pick your iPhone, and Run.
The Simulator cannot do face tracking, so it has to be the device.

The project uses a file-system-synchronized folder for the app target, so new
source files land in the build with no project-file edits.

**Nothing here has been compiled.** It was written on Linux, where there is no
Swift toolchain, so expect some build errors on first open. Paste them and
they'll get fixed.

If the generated project refuses to open, the fallback costs five minutes and
loses nothing: create a blank SwiftUI app named `facetrkr` at the repo root in
Xcode, and the existing `facetrkr/` sources drop straight in because the folder
layout already matches the template.

## M1 acceptance

- Camera permission prompts once, with your purpose string.
- A mask sits on your face and tracks head rotation and translation.
- The console logs the supported face-tracking video formats. Note them — the only
  public data point is 720p-only and it dates from 2018.
- **The spike:** triple-tap the status pill to reveal the debug toggle, then
  flip "Red tint spike" on.
  - Camera feed turns red → `sourceColorTexture` includes passthrough. The
    recording architecture holds and M2/M3 proceed as planned.
  - Only the cube turns red → passthrough is not included. Recording has to
    composite `ARFrame.capturedImage` manually and gets meaningfully harder.

  This claim is inferred from a WWDC21 example rather than documented, which is
  why it's checked before anything is built on top of it.
- Backgrounding and returning doesn't kill the session.

## M4 notes

Four warp effects: bulge eyes, stretch jaw, big head, swirl. Pick one from the
row above the mask carousel.

Intensity is driven by `jawOpen`, so effects wind up as you open your mouth.
That's the first thing in the app that reads blendshapes.

Landmarks are projected with `ARCamera.projectPoint` rather than
`ARView.project`, which keeps it on ARKit's delegate queue instead of hopping to
the main actor 60 times a second. The effect radius follows the head's apparent
size, so effects scale with how close you are to the camera.

**M4 depends on the spike.** Distortion warps the camera image. If
`sourceColorTexture` turns out not to contain passthrough, the kernels are still
correct but there'd be nothing to warp except the props on a transparent
background. Run the spike first.

## M2 and M3 acceptance

- Each of the 17 masks switches cleanly. Watch memory across a full pass of the
  carousel; the mask root is swapped rather than the anchor, so nothing should
  climb.
- Masks are positioned from eyeballed landmark averages in `FaceLandmark`, not
  measured ones. Expect some to sit slightly off on a real face — that enum is
  the one place to nudge.
- Turn your head 45 degrees each way. The goggle arms should disappear behind
  your head rather than passing through it. That's the occlusion mesh working.
- Record 10 seconds, then check the clip in Photos: audio in sync, correct
  orientation, no washed-out colour, and the encoded frame rate matching 60
  rather than showing duplicate frames.
- Record for the full 60 seconds and confirm it finalises cleanly at the cap.
- Record while switching masks mid-clip.

Known things to watch, all flagged in the plan:

- Recording taps the frame *before* it reaches the drawable, so a drawable that
  isn't readable won't break it. But if the passthrough spike fails, the tap is
  capturing 3D content on a transparent background, and the fix is a different
  `FrameSource` implementation rather than a rewrite.
- `providesAudioData` has been reported silently not delivering on some iOS
  builds. Silent video with everything else working points there first.

## Roadmap

| Milestone | Scope | State |
|---|---|---|
| M1 | Face tracking, passthrough spike | built |
| M2 | Procedural props, face occlusion mesh, mask carousel | built |
| M3 | Frame tap, `AVAssetWriter`, save to camera roll | built |
| M4 | Distortion shaders, expression-driven intensity | built |
| M5 | Thermal governor, share sheet | built |
| Next | Real USDZ masks, photo mode, haptics | later |

## Privacy

All face data stays on device. Blendshape coefficients, face meshes and landmarks
are never transmitted or logged. Recorded video is user content that only goes
where the user sends it.

Note this is face *tracking*, not Face ID. Face ID biometrics are never accessible
to apps — `LocalAuthentication` returns pass/fail only. The two are unrelated, and
the term "Face ID" is deliberately absent from the UI and metadata.
