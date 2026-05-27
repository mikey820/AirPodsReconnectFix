# AirPodsReconnectFix  (iOS 6)

A diagnostic + mitigation tweak for the **AirPods Bluetooth disconnect/reconnect
loop on iOS 6**. The AirPods Pro 2/3 pair to an iOS 6 device as a generic
A2DP/HFP stereo headset via Settings (iOS 6 has none of the W1/AAP machinery —
to it they're just a Bluetooth headset). They pair fine and audio is great while
it holds, but after the post-AirPods-Pro-3 firmware update the link drops and
re-establishes every few seconds.

## Honest scope

The likely cause is that the newer AirPods firmware changed something at the
Bluetooth link layer (connection parameters / supervision timeout / link policy)
that the ancient iOS 6 stack mishandles, tearing the link down. That layer lives
in `bluetoothd` and **cannot be safely rewritten blind from a tweak** (crashing
`bluetoothd` in a loop kills Bluetooth system-wide). So this is **not yet a
guaranteed fix** — it is the data-gathering + symptom-mitigation step that makes
a real fix possible.

It does two things, in two processes:

| Process | Behaviour |
|---|---|
| `bluetoothd` | **Read-only.** On load, dumps every Bluetooth/audio Obj-C class (and key method lists) so the next version can target the real connection-management code precisely. No hooks — cannot crash the daemon. |
| `SpringBoard` | Uses `BluetoothManager` (private framework, present on iOS 6) to log every connect / disconnect / connect-fail (with `userInfo`), and **attempts the mitigation**: when the AirPods drop unexpectedly it re-issues `-connect` immediately. Debounced (1.5 s) and rate-capped (max 4 attempts / 60 s) so it can never become its own loop. |

## Pulling the logs — no Mac needed

`os_log` doesn't exist on iOS 6, so everything is written to a plain text file:

```
/var/mobile/Documents/AirPodsReconnectFix.log
```

Open it in **Filza** (or any file manager). Trigger the disconnect loop, then
read/send the file — the `[bluetoothd][class]` / `[bluetoothd][method]` lines and
the `[SpringBoard][disconnect] ... userInfo=` lines are what we need to write the
real low-level fix.

## Tuning

In `Tweak.x`:

- `kAutoReconnectEnabled` — set `NO` for a logging-only build (no state changes).
- `kReconnectDelaySec`, `kMaxAttempts`, `kWindowSec` — mitigation rate limits.

## Build

iOS 6 is 32-bit (`armv7`/`armv7s`), rootful, deployment target 6.0. CI
(`.github/workflows/build.yml`) runs on an older macOS image, pulls an
armv7-capable iPhoneOS SDK (≤ 10.x) into Theos, builds with
`-miphoneos-version-min=6.0`, and attaches the `iphoneos-arm` `.deb` to the
GitHub Release on any `v*` tag. Locally: `make clean all` with `$THEOS` set and
an old SDK in `$THEOS/sdks`.
