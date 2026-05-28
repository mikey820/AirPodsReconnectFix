#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <dlfcn.h>

// AirPodsReconnectFix  (iOS 6 / armv7)
//
// Problem (AirPods Pro 2/3 paired to an iOS 6 device as a generic A2DP/HFP
// Bluetooth headset): they pair fine via Settings, audio is great while it
// holds, but after the post-AirPods-Pro-3 firmware update the link drops and
// re-establishes every few seconds. The likely cause is that the new AirPods
// firmware changed something at the Bluetooth link layer (connection params /
// supervision timeout / link policy) that the ancient iOS 6 stack mishandles,
// tearing the link down. iOS 6 has none of the W1/AAP machinery — to it these
// are just a stereo headset.
//
// We cannot safely rewrite that negotiation blind from a tweak (crashing
// bluetoothd in a loop would take Bluetooth down system-wide). So this build is
// deliberately split:
//
//   * bluetoothd  -> READ-ONLY. Dump the Bluetooth/audio Obj-C runtime so the
//                    next iteration can target the real connection-management
//                    classes precisely. No hooks, nothing that can crash it.
//
//   * SpringBoard -> Use the stable BluetoothManager.framework. Log every
//                    connect / disconnect / connect-fail (with userInfo), and
//                    attempt a mitigation: when our AirPods drop unexpectedly,
//                    re-issue -connect immediately. Debounced + retry-capped so
//                    the mitigation can never become its own runaway loop.
//
// NO MAC NEEDED (and os_log doesn't exist on iOS 6 anyway): everything is
// written to a plain text file on the device that you can open in Filza (or any
// file manager):
//
//   /var/mobile/AirPodsReconnectFix.log
//
// (/var/mobile/Documents doesn't exist on this jailbreak, so we write straight
// to /var/mobile, which always exists and mobile can write to.)
//
// The file is chmod 0666 so both SpringBoard (mobile) and bluetoothd (root) can
// append to it. We also NSLog for good measure.

static dispatch_queue_t gLogQ;
static NSString *const kLogPath = @"/var/mobile/AirPodsReconnectFix.log";

// iOS 6-safe case-insensitive substring test. NSString -containsString: and
// -localizedCaseInsensitiveContainsString: are iOS 8+ ONLY — calling them on
// iOS 6 is an unrecognized selector that crashes the host process (this is what
// was respringing SpringBoard on every disconnect). -rangeOfString:options:
// has existed since iPhoneOS 2.0.
static BOOL strHas(NSString *haystack, NSString *needle) {
    if (![haystack isKindOfClass:[NSString class]] || needle.length == 0) return NO;
    return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

__attribute__((format(__NSString__, 1, 2)))
static void AFLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[AirPodsReconnectFix] %@", msg);

    dispatch_async(gLogQ, ^{
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [NSDate date],
                          NSProcessInfo.processInfo.processName,
                          msg];
        const char *path = kLogPath.fileSystemRepresentation;
        FILE *f = fopen(path, "a");
        if (f) {
            fputs(line.UTF8String, f);
            fclose(f);
            chmod(path, 0666);
        }
    });
}

// ---- Mitigation tunables ---------------------------------------------------
// Auto-reconnect is the only behaviour that changes device state. Everything
// else is pure logging. Flip to NO to ship a logging-only diagnostic build.
static const BOOL  kAutoReconnectEnabled = YES;
// Wait this long after a drop before re-issuing connect (let bluetoothd settle).
static const double kReconnectDelaySec = 1.5;
// Allow at most this many reconnect attempts inside the rolling window before
// backing off — so we never fight a genuinely-gone device or loop forever.
static const int    kMaxAttempts = 4;
static const double kWindowSec   = 60.0;

// ---- Keep-alive ------------------------------------------------------------
// The drop is a dead-regular ~47s cycle. If that's an idle / power-save (sniff)
// timeout, generating a little link traffic before it fires should reset the
// timer and stop the disconnect. We can't touch the link layer from here, but
// reading battery / service state over BluetoothManager does round-trip the
// device, which may be enough to keep the link "warm". Fires comfortably inside
// the ~47s window. (If the drop happens even with this running, it's a true
// link-layer failure that needs daemon access — not an idle timeout.)
// Disabled: proved it does NOT stop the drops, and the drop turned out to be an
// audio-routing glitch, not a link timeout. Kept off to avoid pointless traffic.
static const BOOL   kKeepAliveEnabled = NO;
static const double kKeepAliveSec     = 25.0;

// Bounce the audio route automatically a couple seconds after the AirPods
// connect (when audio is most likely to come up stalled). Debounced.
static const BOOL   kBounceOnConnect  = YES;
static const double kBounceOnConnectDelaySec = 2.0;

// ---- BluetoothManager.framework (private, stable across iOS versions) ------
@interface BluetoothDevice : NSObject
- (NSString *)name;
- (NSString *)address;
- (BOOL)connected;
- (void)connect;
- (void)disconnect;
- (int)batteryLevel;
- (NSArray *)connectedServices;
@end

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)connectedDevices;
- (NSArray *)devices;
@end

static BOOL deviceLooksLikeAirPods(BluetoothDevice *dev) {
    if (![dev respondsToSelector:@selector(name)]) return NO;
    return strHas([dev name], @"airpod");
}

// ---- Audio-route bounce (THE actual fix) -----------------------------------
// Per the bounty owner: the real bug isn't the BT link dropping — it's the
// AUDIO stalling while the AirPods stay connected. The manual cure is to open
// the AirPlay/output picker and switch to the iPhone speaker and back to the
// AirPods a few times. We automate exactly that via MPAudioDeviceController
// (MediaPlayer.framework, private — the iOS-6 equivalent of MPAVRoutingController
// from iOS 7+; the v2.7.1 class dump confirmed it's the right class on this
// device). It exposes pickSpeakerRoute / pickRouteAtIndex: and a numbered list
// of routes via numberOfAudioRoutes + routeNameAtIndex:isPicked:. No daemon
// injection needed; runs entirely in SpringBoard.
static const double kBounceGapSec   = 0.8;   // dwell on each route before flipping
static const int    kBounceRepeats  = 3;     // owner said "a few times"

@interface MPAudioDeviceController : NSObject
+ (void)setRouteDiscoveryEnabled:(BOOL)enabled;
- (id)init;
- (void)setCategory:(NSString *)category;
- (void)setRouteDiscoveryEnabled:(BOOL)enabled;
- (void)clearCachedRoutes;
- (unsigned int)numberOfAudioRoutes;
- (NSString *)routeNameAtIndex:(unsigned int)idx isPicked:(BOOL *)picked;
- (NSString *)nameOfPickedRoute;
- (unsigned int)indexOfPickedRoute;
- (void)pickRouteAtIndex:(unsigned int)idx;
- (void)pickSpeakerRoute;
- (void)restorePickedRoute;
- (BOOL)wirelessRouteIsPicked;
- (BOOL)speakerRouteIsPicked;
- (BOOL)routeOtherThanHandsetIsAvailable;
- (BOOL)routeOtherThanHandsetAndSpeakerIsAvailable;
@end

// Each bounce uses one shared controller so route discovery stays warm across
// the back-and-forth and we don't churn through init/dealloc cycles.
static MPAudioDeviceController *gADC;

static MPAudioDeviceController *audioController(void) {
    if (gADC) return gADC;
    Class C = objc_getClass("MPAudioDeviceController");
    if (!C) { AFLog(@"[route] MPAudioDeviceController class missing"); return nil; }
    // Class-level discovery flag (separate from per-instance) — turn it on first
    // so the very first instance starts populating its cache immediately.
    if ([C respondsToSelector:@selector(setRouteDiscoveryEnabled:)]) {
        [C setRouteDiscoveryEnabled:YES];
    }
    gADC = [[C alloc] init];
    if ([gADC respondsToSelector:@selector(setCategory:)]) {
        // "Playback" is the AVAudioSession playback category string on iOS 6;
        // tells the audio device controller we're picking for media playback so
        // it considers BT A2DP routes as candidates.
        [gADC setCategory:@"Playback"];
    }
    if ([gADC respondsToSelector:@selector(setRouteDiscoveryEnabled:)]) {
        [gADC setRouteDiscoveryEnabled:YES];
    }
    if ([gADC respondsToSelector:@selector(clearCachedRoutes)]) {
        [gADC clearCachedRoutes];
    }
    return gADC;
}

// Discovery is async — after enabling it the cache stays empty for a beat. Spin
// until either we see >1 route OR a non-null route name OR an explicit
// "non-handset-non-speaker route is available" signal, capped so we never
// loop forever. Calls `then` on the main queue once routes look populated.
static const double kRouteWaitStepSec   = 0.4;
static const int    kRouteWaitMaxSteps  = 12;  // ~4.8s ceiling
static void waitForRoutesThen(int step, void(^then)(void)) {
    MPAudioDeviceController *adc = audioController();
    if (!adc) { then(); return; }
    unsigned int n = [adc respondsToSelector:@selector(numberOfAudioRoutes)] ? [adc numberOfAudioRoutes] : 0;
    BOOL hasNamed = NO;
    for (unsigned int i = 0; i < n; i++) {
        BOOL picked = NO;
        NSString *name = [adc routeNameAtIndex:i isPicked:&picked];
        if (name.length > 0) { hasNamed = YES; break; }
    }
    BOOL extra = [adc respondsToSelector:@selector(routeOtherThanHandsetAndSpeakerIsAvailable)]
                 && [adc routeOtherThanHandsetAndSpeakerIsAvailable];
    if ((n > 1 && hasNamed) || extra || step >= kRouteWaitMaxSteps) {
        AFLog(@"[route] routes ready after %d steps (n=%u named=%d extra=%d)",
              step, n, hasNamed, extra);
        then();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRouteWaitStepSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ waitForRoutesThen(step + 1, then); });
}

// Find the route index whose name matches `needle` (case-insensitive substring).
// Returns -1 if none. Used to locate the AirPods route by name after we've
// switched away from it (we can't keep an index — the order can change).
static int routeIndexMatching(MPAudioDeviceController *adc, NSString *needle) {
    if (!adc) return -1;
    unsigned int n = [adc respondsToSelector:@selector(numberOfAudioRoutes)] ? [adc numberOfAudioRoutes] : 0;
    for (unsigned int i = 0; i < n; i++) {
        BOOL picked = NO;
        NSString *name = [adc routeNameAtIndex:i isPicked:&picked];
        if (strHas(name, needle)) return (int)i;
    }
    return -1;
}

// Log every available route + which is picked. Diagnostic, called before bounce.
static void logRoutes(MPAudioDeviceController *adc, NSString *tag) {
    if (!adc) return;
    @try {
        unsigned int n = [adc numberOfAudioRoutes];
        AFLog(@"[route][%@] %u available, picked=%@", tag, n,
              [adc respondsToSelector:@selector(nameOfPickedRoute)] ? [adc nameOfPickedRoute] : @"?");
        for (unsigned int i = 0; i < n; i++) {
            BOOL picked = NO;
            NSString *name = [adc routeNameAtIndex:i isPicked:&picked];
            AFLog(@"[route][%@] [%u] name=%@ picked=%d", tag, i, name, picked);
        }
    } @catch (NSException *e) {
        AFLog(@"[route][EXC log] %@ %@", e.name, e.reason);
    }
}

// One step of the bounce. wantAirPods=NO -> pick speaker; wantAirPods=YES ->
// find AirPods index by name and pick it. Reschedules itself for `remaining`
// more steps with the opposite target, ending on AirPods.
static void bounceStep(int remaining, BOOL wantAirPods) {
    @try {
        MPAudioDeviceController *adc = audioController();
        if (!adc) return;
        if (wantAirPods) {
            int idx = routeIndexMatching(adc, @"airpod");
            // Fallback: any non-handset wireless route (could be named after
            // the device, e.g. "Mikey's AirPods Pro - Find My").
            if (idx < 0) {
                unsigned int n = [adc numberOfAudioRoutes];
                for (unsigned int i = 0; i < n; i++) {
                    BOOL picked = NO;
                    NSString *name = [adc routeNameAtIndex:i isPicked:&picked];
                    if (strHas(name, @"speaker") || strHas(name, @"iphone") || strHas(name, @"receiver")) continue;
                    idx = (int)i; break;
                }
            }
            AFLog(@"[route] step rem=%d -> AirPods idx=%d", remaining, idx);
            if (idx >= 0) [adc pickRouteAtIndex:(unsigned int)idx];
        } else {
            AFLog(@"[route] step rem=%d -> speaker", remaining);
            if ([adc respondsToSelector:@selector(pickSpeakerRoute)]) [adc pickSpeakerRoute];
        }
    } @catch (NSException *e) {
        AFLog(@"[route][EXC step] %@ %@", e.name, e.reason);
    }
    if (remaining <= 0) { AFLog(@"[route] bounce done"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBounceGapSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ bounceStep(remaining - 1, !wantAirPods); });
}

static void resetAudioRoute(NSString *why) {
    MPAudioDeviceController *adc = audioController();
    if (!adc) { AFLog(@"[route] no controller (%@)", why); return; }
    // Kick a fresh discovery cycle so we're not picking against stale/empty cache.
    if ([adc respondsToSelector:@selector(clearCachedRoutes)]) [adc clearCachedRoutes];
    if ([adc respondsToSelector:@selector(setRouteDiscoveryEnabled:)]) [adc setRouteDiscoveryEnabled:YES];
    AFLog(@"[route] waiting for discovery (%@)", why);
    waitForRoutesThen(0, ^{
        MPAudioDeviceController *a = audioController();
        logRoutes(a, why);
        if ([a numberOfAudioRoutes] <= 1) {
            AFLog(@"[route] still only %u route after wait — skipping bounce (%@)",
                  [a numberOfAudioRoutes], why);
            return;
        }
        AFLog(@"[route] bounce start (%@): speaker<->AirPods x%d", why, kBounceRepeats);
        // Start at speaker (NO), bounce 2*repeats-1 more times so we END on AirPods.
        bounceStep(kBounceRepeats * 2 - 1, NO);
    });
}

// Debounced entry point so multiple triggers in quick succession collapse to one
// bounce, and so the bounce always runs on the main thread after a short delay.
static BOOL gRouteResetPending;
static void scheduleRouteReset(NSString *why) {
    if (gRouteResetPending) { AFLog(@"[route] reset already pending, skip (%@)", why); return; }
    gRouteResetPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBounceOnConnectDelaySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gRouteResetPending = NO;
        resetAudioRoute(why);
    });
}

// Manual trigger: `notifyutil -p com.mikey820.airpodsreconnectfix.bounce`, or any
// app/tool posting this Darwin notification, fires a bounce on demand — the
// hands-free version of the owner's "flip the output route" workaround.
static void darwinBounceCb(CFNotificationCenterRef c, void *o, CFStringRef name,
                           const void *obj, CFDictionaryRef info) {
    AFLog(@"[route] darwin trigger received");
    scheduleRouteReset(@"darwin");
}

// Generate a little link traffic to (hopefully) reset an idle/sniff timeout.
//
// CRITICAL: never retain a BluetoothDevice across time. The wrapper holds a raw
// pointer to a daemon-side device struct; retaining the ObjC object does NOT
// keep that struct alive, so poking a stale device later is a dangling-pointer
// crash (SIGSEGV — uncatchable by @try, this is what was crashing SpringBoard).
// So we re-fetch the live connectedDevices fresh on every single tick.
static void keepAliveTick(void) {
    @try {
        Class mgrC = objc_getClass("BluetoothManager");
        BluetoothManager *m = mgrC ? [mgrC sharedInstance] : nil;
        NSArray *devs = [m respondsToSelector:@selector(connectedDevices)] ? [m connectedDevices] : nil;
        BOOL poked = NO;
        for (BluetoothDevice *d in devs) {
            if (!deviceLooksLikeAirPods(d)) continue;
            if (![d respondsToSelector:@selector(connected)] || ![d connected]) continue;
            int batt = [d respondsToSelector:@selector(batteryLevel)] ? [d batteryLevel] : -1;
            AFLog(@"[SpringBoard][keepalive] poked %@ (batt=%d)", [d name], batt);
            poked = YES;
        }
        if (!poked) AFLog(@"[SpringBoard][keepalive] skip (no connected AirPods right now)");
    } @catch (NSException *e) {
        AFLog(@"[SpringBoard][keepalive][EXC] %@ %@", e.name, e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeepAliveSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ keepAliveTick(); });
}

// address -> NSMutableArray<NSDate*> of recent reconnect attempts.
static NSMutableDictionary<NSString *, NSMutableArray<NSDate *> *> *gAttempts;
static dispatch_queue_t gQueue;

// Returns YES if we are still under the rate limit (and records the attempt).
static BOOL underRateLimit(NSString *address) {
    __block BOOL ok = NO;
    dispatch_sync(gQueue, ^{
        NSMutableArray *times = gAttempts[address];
        if (!times) { times = [NSMutableArray array]; gAttempts[address] = times; }
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kWindowSec];
        // drop stale attempts
        while (times.count && [times.firstObject compare:cutoff] == NSOrderedAscending) {
            [times removeObjectAtIndex:0];
        }
        if ((int)times.count < kMaxAttempts) {
            [times addObject:[NSDate date]];
            ok = YES;
        }
    });
    return ok;
}

static void handleDisconnect(BluetoothDevice *dev, NSDictionary *userInfo) {
    NSString *name = [dev respondsToSelector:@selector(name)] ? [dev name] : @"?";
    NSString *addr = [dev respondsToSelector:@selector(address)] ? [dev address] : @"?";
    AFLog(@"[SpringBoard][disconnect] name=%@ addr=%@ userInfo=%@",
          name, addr, userInfo);

    if (!kAutoReconnectEnabled) return;
    if (!deviceLooksLikeAirPods(dev)) {
        AFLog(@"[SpringBoard][disconnect] not AirPods, leaving alone");
        return;
    }
    if (!underRateLimit(addr ?: name)) {
        AFLog(@"[SpringBoard][mitigation] rate limit hit for %@ — backing off", name);
        return;
    }
    AFLog(@"[SpringBoard][mitigation] scheduling reconnect for %@ in %.1fs", name, kReconnectDelaySec);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReconnectDelaySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if ([dev respondsToSelector:@selector(connected)] && [dev connected]) {
                AFLog(@"[SpringBoard][mitigation] %@ already back — no action", name);
                return;
            }
            if ([dev respondsToSelector:@selector(connect)]) {
                AFLog(@"[SpringBoard][mitigation] issuing -connect on %@", name);
                [dev connect];
            }
        } @catch (NSException *e) {
            AFLog(@"[SpringBoard][EXC] reconnect %@: %@ %@", name, e.name, e.reason);
        }
    });
}

static void dumpClassMethods(Class cls, const char *why);  // defined below

// Dump the concrete BluetoothDevice class the first time we actually hold one
// (the 3s startup snapshot can race ahead of any device existing). One shot.
static void dumpDeviceOnce(id obj) {
    static BOOL done = NO;
    if (done || !obj) return;
    if (![obj respondsToSelector:@selector(name)] &&
        ![obj respondsToSelector:@selector(address)]) return;  // not a device
    done = YES;
    dumpClassMethods(object_getClass(obj), "BluetoothDevice");
}

static void observe(NSString *bareName, NSString *label, void (^block)(NSNotification *)) {
    [[NSNotificationCenter defaultCenter] addObserverForName:bareName
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        @try {
            AFLog(@"[SpringBoard][event] %@ object=%@", label, note.object);
            dumpDeviceOnce(note.object);
            block(note);
        } @catch (NSException *e) {
            // Never let our handler take SpringBoard down — just log and move on.
            AFLog(@"[SpringBoard][EXC] %@ in %@ handler: %@ %@",
                  e.name, label, e.reason, e.userInfo);
        }
    }];
}

// Dump every method of a class (incl. its metaclass) so we can spot link-control
// entry points — supervision timeout, low-power/sniff mode, role, keep-alive —
// that we could call to stop the periodic teardown. Read-only.
static void dumpClassMethods(Class cls, const char *why) {
    if (!cls) { AFLog(@"[SpringBoard][dump] %s: class is nil", why); return; }
    AFLog(@"[SpringBoard][dump] %s class=%s ----", why, class_getName(cls));
    for (int meta = 0; meta < 2; meta++) {
        Class c = meta ? object_getClass((id)cls) : cls;  // metaclass = +methods
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            AFLog(@"[SpringBoard][dump] %s %c%s", class_getName(cls),
                  meta ? '+' : '-', sel_getName(method_getName(ms[j])));
        }
        if (ms) free(ms);
    }
}

static void setupSpringBoard(void) {
    AFLog(@"[SpringBoard] installing BluetoothManager observers (autoReconnect=%s)",
          kAutoReconnectEnabled ? "YES" : "NO");

    // Force-load MediaPlayer so MPAudioDeviceController is available the first
    // time we ask for it (we link against it, but make sure it's mapped).
    void *h = dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
    AFLog(@"[route] MediaPlayer dlopen=%p MPAudioDeviceController=%@",
          h, objc_getClass("MPAudioDeviceController") ? @"present" : @"MISSING");
    // Warm route discovery now so the cache is populated by the time AirPods
    // connect — otherwise the first post-connect bounce hits an empty list.
    (void)audioController();

    // These notification names are posted by BluetoothManager. We register for
    // a generous set so we capture whatever this iOS build actually fires.
    observe(@"BluetoothDeviceDisconnectSuccessNotification", @"disconnect", ^(NSNotification *n) {
        handleDisconnect((BluetoothDevice *)n.object, n.userInfo);
    });
    observe(@"BluetoothDeviceConnectSuccessNotification", @"connect", ^(NSNotification *n) {
        if (kBounceOnConnect && deviceLooksLikeAirPods((BluetoothDevice *)n.object)) {
            scheduleRouteReset(@"post-connect");
        }
    });
    observe(@"BluetoothDeviceConnectFailedNotification", @"connect-failed", ^(NSNotification *n) {});
    observe(@"BluetoothDeviceUpdatedNotification", @"device-updated", ^(NSNotification *n) {});
    observe(@"BluetoothConnectabilityChangedNotification", @"connectability", ^(NSNotification *n) {});
    observe(@"BluetoothAvailabilityChangedNotification", @"availability", ^(NSNotification *n) {});

    // Manual on-demand bounce via Darwin notification (hands-free version of the
    // owner's "flip the output route" fix; trigger with notifyutil -p <name>).
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, darwinBounceCb,
        CFSTR("com.mikey820.airpodsreconnectfix.bounce"), NULL,
        CFNotificationSuspensionBehaviorCoalesce);
    AFLog(@"[route] manual trigger ready: notifyutil -p com.mikey820.airpodsreconnectfix.bounce");

    // Start the keep-alive loop once. It self-reschedules and re-fetches the
    // live connected device on every tick, so it's safe whether or not anything
    // is connected yet.
    if (kKeepAliveEnabled) {
        AFLog(@"[SpringBoard][keepalive] starting, every %.0fs", kKeepAliveSec);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeepAliveSec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ keepAliveTick(); });
    }

    // One-shot snapshot of what's currently connected, for context in the logs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class mgr = objc_getClass("BluetoothManager");
        if (!mgr) { AFLog(@"[SpringBoard] BluetoothManager class not found"); return; }
        BluetoothManager *m = [mgr sharedInstance];
        AFLog(@"[SpringBoard] snapshot connectedDevices=%@", [m connectedDevices]);

        // One-time surface dump. The daemon-side classes only load into BTServer
        // (needs a reboot to inject), but BluetoothManager/BluetoothDevice live
        // here in SpringBoard, so dump what we can reach right now.
        dumpClassMethods(mgr, "BluetoothManager");
        NSArray *known = [m respondsToSelector:@selector(devices)] ? [m devices]
                       : [m respondsToSelector:@selector(connectedDevices)] ? [m connectedDevices]
                       : nil;
        AFLog(@"[SpringBoard] known devices count=%u", (unsigned)known.count);
        if (known.count) {
            // They share a class; dumping one concrete BluetoothDevice is enough.
            dumpClassMethods(object_getClass(known[0]), "BluetoothDevice");
        } else {
            AFLog(@"[SpringBoard] no devices to dump class from — reconnect AirPods then re-grab log");
        }
    });
}

// ---- bluetoothd: read-only runtime dump ------------------------------------
static void dumpBluetoothdRuntime(void) {
    AFLog(@"[bluetoothd] runtime dump start");
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    int logged = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *cn = class_getName(classes[i]);
        if (!cn) continue;
        NSString *name = @(cn);
        BOOL interesting =
            strHas(name, @"Bluetooth") ||
            [name hasPrefix:@"BT"] ||
            strHas(name, @"Audio") ||
            strHas(name, @"Connection") ||
            strHas(name, @"Link") ||
            strHas(name, @"Accessory") ||
            strHas(name, @"Device");
        if (!interesting) continue;
        AFLog(@"[bluetoothd][class] %s", cn);
        logged++;
        // For the most promising connection-management classes, also dump
        // method names so the next iteration knows what to hook.
        if (strHas(name, @"Connection") ||
            strHas(name, @"Link") ||
            strHas(name, @"Device")) {
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(classes[i], &mcount);
            for (unsigned int j = 0; j < mcount; j++) {
                AFLog(@"[bluetoothd][method] %s -%s",
                      cn, sel_getName(method_getName(methods[j])));
            }
            if (methods) free(methods);
        }
    }
    if (classes) free(classes);
    AFLog(@"[bluetoothd] runtime dump done (%d interesting of %u classes)", logged, count);
}

%ctor {
    @autoreleasepool {
        gLogQ = dispatch_queue_create("com.mikey820.airpodsreconnectfix.log", DISPATCH_QUEUE_SERIAL);
        gAttempts = [NSMutableDictionary dictionary];
        gQueue = dispatch_queue_create("com.mikey820.airpodsreconnectfix.q", DISPATCH_QUEUE_SERIAL);

        NSString *proc = NSProcessInfo.processInfo.processName;
        AFLog(@"[ctor] loaded into process %@", proc);

        // iOS 6's BT stack is BTServer (+ helper daemons BTServerAVRCP /
        // BTServerMap / BlueTool); bluetoothd is the later name. Run the runtime
        // dump in any of them so we capture wherever the link control lives.
        @try {
            if ([proc isEqualToString:@"SpringBoard"]) {
                setupSpringBoard();
            } else {
                // Any non-SpringBoard process we were injected into is a BT
                // daemon (per the filter) — dump its runtime.
                dumpBluetoothdRuntime();
            }
        } @catch (NSException *e) {
            // Critically, never crash the BT daemon or SpringBoard at load.
            AFLog(@"[ctor][EXC] %@ in %@: %@", e.name, proc, e.reason);
        }
    }
}
