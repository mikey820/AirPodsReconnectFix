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
//   /var/mobile/Documents/AirPodsReconnectFix.log
//
// The file is chmod 0666 so both SpringBoard (mobile) and bluetoothd (root) can
// append to it. We also NSLog for good measure.

static dispatch_queue_t gLogQ;
static NSString *const kLogPath = @"/var/mobile/Documents/AirPodsReconnectFix.log";

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

// ---- BluetoothManager.framework (private, stable across iOS versions) ------
@interface BluetoothDevice : NSObject
- (NSString *)name;
- (NSString *)address;
- (BOOL)connected;
- (void)connect;
- (void)disconnect;
@end

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)connectedDevices;
- (NSArray *)devices;
@end

static BOOL deviceLooksLikeAirPods(BluetoothDevice *dev) {
    if (![dev respondsToSelector:@selector(name)]) return NO;
    NSString *n = [dev name];
    return n.length && [n localizedCaseInsensitiveContainsString:@"airpod"];
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
        if ([dev respondsToSelector:@selector(connected)] && [dev connected]) {
            AFLog(@"[SpringBoard][mitigation] %@ already back — no action", name);
            return;
        }
        if ([dev respondsToSelector:@selector(connect)]) {
            AFLog(@"[SpringBoard][mitigation] issuing -connect on %@", name);
            [dev connect];
        }
    });
}

static void observe(NSString *bareName, NSString *label, void (^block)(NSNotification *)) {
    [[NSNotificationCenter defaultCenter] addObserverForName:bareName
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        AFLog(@"[SpringBoard][event] %@ object=%@", label, note.object);
        block(note);
    }];
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
            [name containsString:@"Bluetooth"] ||
            [name hasPrefix:@"BT"] ||
            [name containsString:@"Audio"] ||
            [name containsString:@"Connection"] ||
            [name containsString:@"Link"] ||
            [name containsString:@"Accessory"] ||
            [name containsString:@"Device"];
        if (!interesting) continue;
        AFLog(@"[bluetoothd][class] %s", cn);
        logged++;
        // For the most promising connection-management classes, also dump
        // method names so the next iteration knows what to hook.
        if ([name containsString:@"Connection"] ||
            [name containsString:@"Link"] ||
            [name containsString:@"Device"]) {
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

        // iOS 6's Bluetooth daemon is BTServer; bluetoothd is the later name.
        // Match both so the runtime dump runs wherever the BT stack lives.
        if ([proc isEqualToString:@"BTServer"] || [proc isEqualToString:@"bluetoothd"]) {
            dumpBluetoothdRuntime();
        } else if ([proc isEqualToString:@"SpringBoard"]) {
            setupSpringBoard();
        }
    }
}
