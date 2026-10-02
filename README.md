# MixTap

A native macOS menu-bar prototype that mixes desktop audio and a selected microphone into a WAV. Normal playback stays on the output device you already use; MixTap never changes the system's default input or output.

This first milestone is a recorder, not yet a virtual input device. The intended next milestone is a small HAL Audio Server plug-in that publishes the mix to Screenshot, QuickTime, and other apps.

## Build and open

Requires macOS 14.2 or later and a recent Apple Command Line Tools or Xcode installation. No third-party packages are needed.

```sh
./scripts/build.sh
open build/MixTap.app
```

Click the waveform icon in the menu bar. There is no Dock icon or main window. Builds are for the current Mac's architecture and are ad-hoc signed for local testing. A paid developer account is not needed for this build step. Public/private distribution signing and notarization are not configured yet.

To use Xcode's toolchain without changing the system-wide selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build.sh
```

Quit MixTap before rebuilding it. Ad-hoc rebuilds can require macOS to grant capture permission again. When we have a stable signing identity, the build script accepts `MIXTAP_SIGNING_IDENTITY`.

## First recording

1. Keep your usual speakers/headphones selected in macOS. Headphones make it easier to verify each source without the microphone picking up speaker playback.
2. Click MixTap's waveform icon and choose the microphone, for example **MacBook Pro Microphone**. Selection is explicit on first launch and remembered afterward. For multichannel interfaces, this prototype uses **input channel 1**, centered in stereo.
3. Click **Record WAV…**, allow microphone access, and choose a new filename. Allow system audio recording if macOS prompts. If macOS requires quitting after a permission change, reopen MixTap and start again.
4. Play some desktop audio and speak. Both source meters should move. Use the dB sliders and mute buttons to check that each source contributes separately. The sliders start at −6 dB each to leave some mixing headroom.
5. Click **Stop & save**, then **Show file**. Listen to the saved WAV.

The controls range from −60 to +12 dB, in 0.5 dB steps, with a separate true mute. Source meters show levels after gain/mute. The output meter flags peaks above 0 dBFS. Float WAV preserves those peaks, but many playback paths clip them; lower the source levels if the overload warning appears. Microphone monitoring is not enabled.

If a source is missing, check **System Settings → Privacy & Security → Microphone** and **Screen & System Audio Recording** (the exact label varies with macOS). A running tap can return silence, so successful startup alone does not prove that system audio access was granted. Play known audio and verify the desktop meter and WAV. MixTap does not bypass permissions.

## Prototype boundaries

- Desktop capture uses a private, unmuted global Core Audio stereo tap, excluding MixTap itself. It can include application audio routed to multiple devices; it is not restricted to the selected output device.
- The tap's aggregate device is private, temporary, and contains no microphone. Users do not configure aggregate or multi-output devices. The selected microphone is captured independently.
- Audio callbacks only copy float samples and timestamps into preallocated single-producer/single-consumer queues. A worker aligns the streams on the host clock, mixes at 48 kHz, and writes the file. Gain changes are ramped.
- The current timestamp-based sample-rate conversion uses **linear interpolation**. It compensates for clock drift in synthetic tests but is not a production-quality band-limited asynchronous resampler. Better SRC and real hardware soak tests are required before the virtual-device release.
- The worker uses approximately 150 ms of buffering. This is a diagnostic recording prototype, not a low-latency monitoring path.
- A microphone or desktop format change, default output change, device loss, or sleep stops and finalizes the recording. Choose devices and start again. Seamless switching is not implemented. Microphone selection is disabled while recording.
- Missing samples become silence; queue overflow is reported in the UI. No-signal and permission checks still require a listening test. The ring buffers are bounded, and a worker stall longer than a second stops the recording.
- Supported input: native little-endian Float32 Core Audio streams, 8–192 kHz, up to 8,192 frames per callback. Multi-stream layouts beyond the first microphone channel / desktop stereo pair are not supported.
- Recordings use 48 kHz, stereo, 32-bit float WAV and stop before 3.8 GB (approximately 2 hours 45 minutes). Existing files are never overwritten.
- Normal Stop, Quit, and sleep finalize WAV headers. Force-quitting or crashing is not guaranteed to leave a playable file; crash recovery is future work.

## Tests

```sh
./scripts/test.sh
MIXTAP_TEST_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' ./scripts/test.sh
```

Tests cover gain and mute ramps, stereo mixing, missing audio, gaps, queue overflow/wraparound, concurrent publication, two simulated 30-minute clock-drift runs (44.1 kHz / +250 ppm and 48 kHz / −250 ppm), and WAV metadata, duration, exact sample readback, finalization, and overwrite protection. They do not request capture permission or record real audio.

Manual acceptance still needed on the target Mac:

- Record desktop-only, mic-only, and a mix; verify both mute buttons and live gain changes.
- Verify that system playback volume still works. Characterize whether the captured tap level changes with output volume on each output device; do not assume all device paths behave identically.
- Run a long recording with distinct timing cues to assess drift and discontinuities.
- Check denied permissions, unplugging the mic, output switching, sleep/wake, repeated start/stop, and Quit during recording.
- Test Bluetooth separately; opening a Bluetooth headset microphone may change the headset's playback mode, a macOS/device behavior.

## Code map and next milestone

- `Sources/App/MixTapApp.swift`: SwiftUI menu bar, input selection, permission flow, meters, and recording lifecycle.
- `Sources/Audio/AudioBridge.mm`: Core Audio device/tap ownership and worker lifecycle.
- `Sources/Audio/AudioCore.hpp`: bounded timestamped capture queues and the mixer.
- `Sources/Audio/WaveWriter.hpp`: WAV sink, separate from capture and mixing.
- `Resources/Info.plist`: app identity and capture permission descriptions.

After validating capture, replace/improve the prototype resampler, then add a shared-memory sink and a minimal input-only `MixTap.driver`. The driver should expose 48 kHz stereo, emit silence when the app disappears, and keep capture, UI, file IO, and configuration out of `coreaudiod`. A signed/notarized installer comes after that. No HAL plug-in is installed by this prototype.

Apple references: [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [virtual audio device guidance](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver), [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
