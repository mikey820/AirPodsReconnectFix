# AirPodsReconnectFix (iOS 6)

Add my repo for an easy install! https://mikey820.github.io/repo/

Fixes **AirPods on iOS 6** after the post–AirPods-Pro-3 firmware update, on two
fronts that the new firmware broke:

1. **The disconnect/reconnect loop** — the link drops and re-establishes every
   ~45 seconds.
2. **The pause/skip audio-routing bug** — when you pause, skip a track, or play a
   short system sound, audio stops routing to the AirPods (it falls back to the
   speaker/receiver) even though the AirPods stay connected, until you manually
   flip the output in the route picker.

The AirPods Pro 2/3 pair to an iOS 6 device as a generic A2DP/HFP stereo headset
(iOS 6 has none of the W1/AAP machinery — to it they're just a Bluetooth
headset). They pair fine and sound great while everything holds; the two bugs
above are what the newer firmware introduced.

## ❤️ Support the Project

If you find this project useful and would like to support development, donations are appreciated.

### Litecoin
**Network:** Litecoin (LTC)  
**Address:** `ltc1qaz2zqcc5usl4ueg7w5m8kqcmvrfqurpn6wqyfa`

Please double-check that you're sending on the **Litecoin** network.

Thank you for your support!

## How it works

Everything runs in **SpringBoard** via the private but stable
`BluetoothManager` framework. No daemon patching, no system files touched.

### 1. Disconnect fix — pre-emptive service re-assert

The drop is a dead-regular ~45 s timer the new firmware enforces; mere link
*activity* (battery polls, a silent audio stream) does **not** reset it. What
does: every **18 s** while the AirPods are connected, the tweak re-runs the
host-side service-connect handshake (`-connectWithServices:` on the live
device). That lands before the firmware's teardown deadline and keeps resetting
it, so the link stays up. A **burst-reconnect** fallback (a tight sequence of
`-connect` attempts, debounced and rate-capped) catches any drop that still
slips through and brings the AirPods back in ~2 s, optionally resuming whatever
was playing.

### 2. Pause/skip routing fix — gapless A2DP keep-warm

On iOS 6 the A2DP route goes idle the instant the media stream stops or gaps
(pause, the brief silence when skipping a track, or between short system
sounds), and the stack then fails to re-point the next sound back to the
AirPods. The fix is to never let the route go idle: the tweak plays a
continuous, **inaudible** stream so A2DP stays active across those gaps and audio
keeps flowing to the AirPods.

Two details make it reliable:

- A real ~60 s **silent MP3** decoded by `AVAudioPlayer` (embedded in the dylib;
  nothing to download or bundle separately).
- **Overlapping players** — a fresh player starts every 50 s while the previous
  60 s clip is still playing, so there is never a gap at a loop boundary.

The session category is `Playback` + `MixWithOthers`, so the silence layers
*under* real music and never interrupts, ducks, or pauses it. The stream starts
when the AirPods connect and stops when they disconnect.

## Logs — no Mac needed

`os_log` doesn't exist on iOS 6, so everything is written to a plain text file:

```
/var/mobile/AirPodsReconnectFix.log
```

Open it in **Filza** (or any file manager). Useful markers:
`[SpringBoard][preempt] RE-ASSERT` (disconnect fix firing), `[warm] ON/OFF`
(keep-warm engine following the AirPods connection), and
`[SpringBoard][disconnect] … userInfo=` (a drop the firmware forced).

## Build

iOS 6 is 32-bit (`armv7`), rootful, deployment target 6.0. CI
(`.github/workflows/build.yml`) runs on **Linux** (its linker still supports
armv7), pulls an armv7-capable iPhoneOS SDK (≤ 10.x) into Theos, and attaches the
`iphoneos-arm` `.deb` to the GitHub Release on any `v*` tag. Locally:
`make clean all` with `$THEOS` set and an old SDK in `$THEOS/sdks`.
