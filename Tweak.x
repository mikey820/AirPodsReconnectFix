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
// AirPods a few times. We automate exactly that via MPAVRoutingController
// (MediaPlayer.framework, private; introduced in iOS 6 — perfect for us), which
// is what the system route picker itself drives. This needs NO daemon injection.
static const double kBounceGapSec   = 0.8;   // dwell on speaker before going back
static const int    kBounceRepeats  = 3;     // owner said "a few times"

@interface MPAVRoute : NSObject
- (NSString *)routeName;
- (NSString *)routeUID;
- (long long)routeType;
- (NSUInteger)routeSubtype;
- (BOOL)isPicked;
@end

@interface MPAVRoutingController : NSObject
- (id)init;
- (NSArray *)availableRoutes;
- (BOOL)pickRoute:(MPAVRoute *)route;
- (MPAVRoute *)pickedRoute;
@end

static BOOL routeIsSpeaker(MPAVRoute *r) {
    NSString *n = [r respondsToSelector:@selector(routeName)] ? [r routeName] : nil;
    // Built-in output is named "iPhone"/"Speaker"/"Receiver" depending on build.
    return strHas(n, @"speaker") || strHas(n, @"iphone") || strHas(n, @"receiver");
}
static BOOL routeIsAirPods(MPAVRoute *r) {
    NSString *n = [r respondsToSelector:@selector(routeName)] ? [r routeName] : nil;
    return strHas(n, @"airpod");
}

// One step of the bounce: pick `wantAirPods ? AirPods : speaker`, then schedule
// the opposite, repeating a few times so the audio path gets fully re-kicked.
static void bounceStep(int remaining, BOOL wantAirPods) {
    @try {
        Class C = objc_getClass("MPAVRoutingController");
        if (!C) { AFLog(@"[route] MPAVRoutingController not found"); return; }
        MPAVRoutingController *rc = [[C alloc] init];
        NSArray *routes = [rc availableRoutes];
        MPAVRoute *target = nil, *speaker = nil, *pods = nil;
        for (MPAVRoute *r in routes) {
            if (routeIsSpeaker(r)) speaker = r;
            if (routeIsAirPods(r)) pods = r;
        }
        target = wantAirPods ? pods : speaker;
        AFLog(@"[route] step rem=%d want=%@ -> target=%@ (speaker=%@ pods=%@)",
              remaining, wantAirPods ? @"AirPods" : @"speaker",
              [target respondsToSelector:@selector(routeName)] ? [target routeName] : @"<nil>",
              speaker ? @"y" : @"n", pods ? @"y" : @"n");
        if (target) [rc pickRoute:target];
    } @catch (NSException *e) {
        AFLog(@"[route][EXC] %@ %@", e.name, e.reason);
    }
    if (remaining <= 0) { AFLog(@"[route] bounce done"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBounceGapSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ bounceStep(remaining - 1, !wantAirPods); });
}

// Log the current routes (diagnostic) then bounce speaker<->AirPods a few times,
// ending back on the AirPods.
static void resetAudioRoute(NSString *why) {
    @try {
        Class C = objc_getClass("MPAVRoutingController");
        if (!C) { AFLog(@"[route] MPAVRoutingController unavailable (%@)", why); return; }
        MPAVRoutingController *rc = [[C alloc] init];
        for (MPAVRoute *r in [rc availableRoutes]) {
            AFLog(@"[route] avail name=%@ type=%lld picked=%d",
                  [r respondsToSelector:@selector(routeName)] ? [r routeName] : @"?",
                  [r respondsToSelector:@selector(routeType)] ? [r routeType] : -1,
                  [r respondsToSelector:@selector(isPicked)] ? [r isPicked] : -1);
        }
    } @catch (NSException *e) {
        AFLog(@"[route][EXC enum] %@ %@", e.name, e.reason);
    }
    AFLog(@"[route] bounce start (%@): speaker<->AirPods x%d", why, kBounceRepeats);
    // Start by going to the speaker; bounce ends on AirPods. Total picks ~= 2*repeats.
    bounceStep(kBounceRepeats * 2 - 1, NO);
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

// One-time diagnostic: enumerate every MediaPlayer class that looks audio/route/
// device-related and dump its method list. MPAVRoutingController is iOS 7+ — on
// iOS 6 the equivalent is a different private class (likely MPAudioDeviceController
// or MPVolumeController), and we don't know its exact API without seeing it. This
// dump tells v2.7.2 which class to use and what selectors to call.
static void dumpMediaPlayerClassesOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    // Force-load MediaPlayer — we link against it, but make sure it's mapped
    // before we ask the runtime for its classes.
    void *h = dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
    AFLog(@"[route][dump] MediaPlayer dlopen=%p", h);
    unsigned int n = 0;
    Class *L = objc_copyClassList(&n);
    int hits = 0;
    for (unsigned int i = 0; i < n; i++) {
        const char *cn = class_getName(L[i]);
        if (!cn || cn[0] != 'M' || cn[1] != 'P') continue;
        NSString *name = @(cn);
        BOOL interesting = strHas(name, @"Route") || strHas(name, @"Audio") ||
                           strHas(name, @"Device") || strHas(name, @"Output") ||
                           strHas(name, @"AV") || strHas(name, @"Volume") ||
                           strHas(name, @"AirPlay") || strHas(name, @"Picker");
        if (!interesting) continue;
        AFLog(@"[route][class] %s", cn);
        hits++;
        // For controller-type classes (the ones likely to expose a pick/select
        // API), also dump every instance + class method so we can read off the
        // right entry point.
        if (strHas(name, @"Controller")) {
            for (int meta = 0; meta < 2; meta++) {
                Class c = meta ? object_getClass((id)L[i]) : L[i];
                unsigned int mc = 0;
                Method *ms = class_copyMethodList(c, &mc);
                for (unsigned int j = 0; j < mc; j++) {
                    AFLog(@"[route][meth] %s %c%s", cn,
                          meta ? '+' : '-', sel_getName(method_getName(ms[j])));
                }
                if (ms) free(ms);
            }
        }
    }
    if (L) free(L);
    AFLog(@"[route][dump] %d candidate MP audio/route classes", hits);
}

static void setupSpringBoard(void) {
    AFLog(@"[SpringBoard] installing BluetoothManager observers (autoReconnect=%s)",
          kAutoReconnectEnabled ? "YES" : "NO");

    // Run the MP class dump once at startup so the next build knows the iOS-6
    // routing API. MPAVRoutingController is iOS 7+ and confirmed missing here.
    dumpMediaPlayerClassesOnce();

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
