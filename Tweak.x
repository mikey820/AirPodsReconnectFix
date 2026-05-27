#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>

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
static const BOOL   kKeepAliveEnabled = YES;
static const double kKeepAliveSec     = 25.0;

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

// The AirPods device we're currently tracking, for keep-alive. Strong ref under
// ARC; refreshed whenever we see the device in a notification.
static BluetoothDevice *gAirPods;
static BOOL gKeepAliveRunning;

// Generate a little link traffic to (hopefully) reset an idle/sniff timeout.
static void keepAliveTick(void) {
    @try {
        BluetoothDevice *d = gAirPods;
        BOOL connected = d && [d respondsToSelector:@selector(connected)] && [d connected];
        if (connected) {
            if ([d respondsToSelector:@selector(batteryLevel)])      (void)[d batteryLevel];
            if ([d respondsToSelector:@selector(connectedServices)]) (void)[d connectedServices];
            AFLog(@"[SpringBoard][keepalive] poked %@ (connected, batt=%d)",
                  [d respondsToSelector:@selector(name)] ? [d name] : @"?",
                  [d respondsToSelector:@selector(batteryLevel)] ? [d batteryLevel] : -1);
        } else {
            AFLog(@"[SpringBoard][keepalive] skip (no connected AirPods tracked)");
        }
    } @catch (NSException *e) {
        AFLog(@"[SpringBoard][keepalive][EXC] %@ %@", e.name, e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeepAliveSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ keepAliveTick(); });
}

// Remember an AirPods device when we see it, and kick off the keep-alive loop once.
static void trackAirPods(BluetoothDevice *dev) {
    if (!deviceLooksLikeAirPods(dev)) return;
    gAirPods = dev;
    if (kKeepAliveEnabled && !gKeepAliveRunning) {
        gKeepAliveRunning = YES;
        AFLog(@"[SpringBoard][keepalive] starting, every %.0fs", kKeepAliveSec);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKeepAliveSec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ keepAliveTick(); });
    }
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
            trackAirPods((BluetoothDevice *)note.object);
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

    // These notification names are posted by BluetoothManager. We register for
    // a generous set so we capture whatever this iOS build actually fires.
    observe(@"BluetoothDeviceDisconnectSuccessNotification", @"disconnect", ^(NSNotification *n) {
        handleDisconnect((BluetoothDevice *)n.object, n.userInfo);
    });
    observe(@"BluetoothDeviceConnectSuccessNotification", @"connect", ^(NSNotification *n) {});
    observe(@"BluetoothDeviceConnectFailedNotification", @"connect-failed", ^(NSNotification *n) {});
    observe(@"BluetoothDeviceUpdatedNotification", @"device-updated", ^(NSNotification *n) {});
    observe(@"BluetoothConnectabilityChangedNotification", @"connectability", ^(NSNotification *n) {});
    observe(@"BluetoothAvailabilityChangedNotification", @"availability", ^(NSNotification *n) {});

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
