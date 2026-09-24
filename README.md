# facetrkr

Face-tracked 3D masks and distortion effects on iPhone, recorded to video.

Native ARKit + RealityKit. No third-party AR SDK.

---

## Start here

Everything compiles green on CI, but nothing has ever been run. These are the
steps from a fresh clone to the app on your phone.

### 1. Open it

```bash
git clone https://github.com/Git-Dann/gitface-app ~/Developer/gitface-app
cd ~/Developer/gitface-app
git checkout claude/gifted-allen-fkkh38
open facetrkr.xcodeproj
```

### 2. Set the signing team

Click **facetrkr** at the top of the sidebar, then the **facetrkr** target, then
**Signing & Capabilities**. Set **Team** to Gitwork Ltd. The bundle ID is
already `co.gitwork.facetrkr`.

### 3. Run on the phone

Plug the iPhone in, unlock it, pick it from the device dropdown, press **⌘R**.
The Simulator cannot do face tracking, so it has to be a real device.

The first launch fails with "Untrusted Developer". That is normal. On the phone:
**Settings → General → VPN & Device Management → Gitwork Ltd → Trust**, then
press ⌘R again.

### 4. Run the passthrough test

This is the one measurement the whole design rests on.

**Triple-tap the status pill** at the top of the screen to reveal the debug
toggle, then turn on **Red tint spike**.

| What you see | What it means |
|---|---|
| Camera feed and background go red | `sourceColorTexture` includes passthrough. Recording and distortion work as designed. |
| Only the mask goes red | Passthrough is absent. Recording captures props on a transparent background, distortion has nothing to warp, and the frame source needs a different implementation. |

That claim comes from a WWDC21 example rather than documentation, which is why
it is checked before anything is built on top of it.

### 5. Note the capture resolution

Filter the Xcode console for `facetrkr`. The `face video format:` lines list
what the device offers, and the `using …` line says which was chosen.

Measured on an iPhone with Face ID, September 2026:

```
1920x1440 @ 30    1920x1080 @ 60    1440x1080 @ 60/30    1280x720 @ 60/30
```

Worth recording because the only public figure for this was 720p-only and dated
from 2018, which is what the code originally assumed. The app now selects
1920x1080 at 60fps, which in portrait is exactly the 1080x1920 encode size.

### Expect rough edges

Mask positions come from eyeballed landmark averages in `FaceLandmark`
(`facetrkr/AR/MaskLibrary.swift`), not measured ones, so some props will sit
wrong on a real face. That enum is the single place to correct them.

---

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

## Repository notes

The Xcode project is generated and committed, so there is nothing to assemble.
The app target uses a file-system-synchronized folder, so new source files land
in the build with no project-file edits.

The `Build for iOS` workflow compiles the project on a macOS runner with signing
disabled, which is what keeps the code honest: it was written on Linux, where
there is no Swift toolchain.

If the project ever refuses to open, the fallback costs five minutes and loses
nothing: create a blank SwiftUI app named `facetrkr` at the repo root in Xcode,
and the existing `facetrkr/` sources drop straight in, because the folder layout
already matches the template.

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

## TestFlight

Builds are signed and uploaded by the `TestFlight` workflow, so no Mac is
involved. Tag a commit `v0.2` and push it, or run the workflow by hand from the
Actions tab.

### One-off setup

1. **Create the app record.** In App Store Connect, add a new iOS app with the
   bundle ID `co.gitwork.facetrkr`. Signing assets are created automatically by
   the workflow, but the app record is not, and the upload fails without it.

2. **Create an App Store Connect API key.** Users and Access → Integrations →
   App Store Connect API → Team Keys. Give it the **App Manager** role. The
   `.p8` downloads exactly once, so keep it somewhere safe.

3. **Add four repository secrets** (Settings → Secrets and variables → Actions):

   | Secret | Where it comes from |
   |---|---|
   | `APP_STORE_CONNECT_KEY_ID` | Shown next to the key you just made |
   | `APP_STORE_CONNECT_ISSUER_ID` | At the top of the same Keys page |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | The full contents of the `.p8`, `BEGIN`/`END` lines included |
   | `APPLE_TEAM_ID` | Developer portal → Membership details |

The build number comes from the Actions run number, because App Store Connect
refuses a build number it has seen before. The marketing version comes from the
tag.

### Things worth knowing before the first upload

- **This repo is public.** GitHub withholds secrets from fork pull requests, and
  this workflow only runs on tag pushes and manual dispatch, both of which need
  write access. That is sound, but these are company credentials, so consider
  putting the job behind a protected Environment so uploads need an approval.

- **Internal vs external testers.** Internal testers have to be users on
  Gitwork Ltd's App Store Connect account, capped at 100, and get builds
  immediately. Anyone outside the company is an external tester, which means
  Beta App Review on the first build and needs a privacy policy URL. For mates
  outside Gitwork, budget for that rather than expecting an instant link.

- **A privacy policy is not optional here.** The Apple Developer Program License
  Agreement requires one describing the use of face data for any app using
  ARKit face tracking. This app keeps all face data on device, which makes the
  policy short, but it still has to exist.

- **Export compliance** is pre-answered in the project
  (`ITSAppUsesNonExemptEncryption = NO`), since the app ships no encryption of
  its own. Without it, every single upload stops and asks.

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
