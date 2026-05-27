# AirPodsReconnectFix

A diagnostic + mitigation tweak for the **AirPods Pro disconnect/reconnect loop on iOS 16**
that appeared after the post–AirPods Pro 3 firmware update: AirPods pair fine,
audio is great while it holds, but the link drops and re-establishes every few
seconds.

## Honest scope

The root cause almost certainly lives in `bluetoothd`'s LE connection-parameter /
supervision-timeout negotiation — the newer AirPods firmware advertises
something the older iOS 16 stack mishandles, tearing the link down. That layer
**cannot be safely rewritten blind from a tweak** (crashing `bluetoothd` in a
loop kills Bluetooth system-wide). So this is **not yet a guaranteed fix** — it
is the data-gathering + symptom-mitigation step that makes a real fix possible.

It does two things, in two processes:

| Process | Behaviour |
|---|---|
| `bluetoothd` | **Read-only.** On load, dumps every Bluetooth/audio Obj-C class (and key method lists) so the next version can hook the real connection-management code precisely. No hooks — cannot crash the daemon. |
| `SpringBoard` | Uses `BluetoothManager.framework` to log every connect / disconnect / connect-fail (with `userInfo`), and **attempts the mitigation**: when the AirPods drop unexpectedly it re-issues `-connect` immediately. Debounced (1.5 s) and rate-capped (max 4 attempts / 60 s) so it can never become its own loop. |

## Pulling the logs (this is the important part)

All output uses the `os_log` subsystem `com.mikey820.airpodsreconnectfix`.
With the device connected to a Mac:

```sh
# live
log stream --predicate 'subsystem == "com.mikey820.airpodsreconnectfix"'

# capture a window, then open in Console.app and filter on the subsystem
log collect --device --last 5m
```

Trigger a disconnect loop while capturing, then send the log — the
`[bluetoothd][class]` / `[bluetoothd][method]` lines and the
`[SpringBoard][disconnect] ... userInfo=` lines are what we need to write the
real low-level fix.

## Tuning

In `Tweak.x`:

- `kAutoReconnectEnabled` — set `NO` for a logging-only build (no state changes).
- `kReconnectDelaySec`, `kMaxAttempts`, `kWindowSec` — mitigation rate limits.

## Build

CI (`.github/workflows/build.yml`, macOS runner + Theos) builds both rootless
and rootful `.deb`s on any `v*` tag and attaches them to the GitHub Release.
Locally: `make clean all` with `$THEOS` set.

Rootless target is intended for Dopamine.
