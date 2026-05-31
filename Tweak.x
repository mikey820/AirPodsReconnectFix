#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
// Burst-retry connect at these offsets (seconds) after the disconnect fires.
// The first one is essentially synchronous — goal is to issue -connect before
// iOS's audio session times out and pauses music. Subsequent retries cover the
// case where the first attempt lands before BTServer is ready to honor it.
static const double kBurstDelaysSec[] = { 0.0, 0.25, 0.6, 1.2 };
static const int    kBurstCount       = (int)(sizeof(kBurstDelaysSec)/sizeof(kBurstDelaysSec[0]));
// Allow at most this many reconnect BURSTS inside the rolling window before
// backing off — so we never fight a genuinely-gone device or loop forever.
// (One burst = up to kBurstCount -connect calls for the same disconnect.)
static const int    kMaxAttempts = 6;
static const double kWindowSec   = 60.0;

// ---- Pre-emptive service re-assert -----------------------------------------
// The drop is a dead-regular ~45s cycle (every disconnect in the logs lands
// 42–49s after the prior connect — a timer firing, not interference). Two forms
// of mere link *activity* have already FAILED to stop it: (1) reading
// battery/service state every 25s, and (2) a continuous silent A2DP stream
// (asentientbot's ios-6-pods-hack). So the new firmware tears the ACL link down
// on its own timer regardless of traffic. The one host-side lever left untried:
// actively RE-ASSERT the service connection via -connectWithServices: a few
// seconds before the ~45s deadline, in case re-running the service-connect path
// resets whatever timer the firmware counts. Anchored to each connect (not
// wall-clock) and generation-gated so a disconnect cancels pending re-asserts.
// DECISION GATE: if the next log STILL shows ~45s drops with these re-asserts
// firing, pre-emption from a userspace tweak is conclusively dead and we pivot
// to making the reconnect itself seamless instead.
static const double kPreemptIntervalSec = 18.0;  // pokes at ~18s, 36s … < 45s

// Bounce the audio route automatically a couple seconds after AirPods connect.
// DISABLED: confirmed on-device that the speaker leg of the bounce pauses the
// active music session and it doesn't auto-resume — net effect is worse than
// no fix. The manual Darwin trigger (notifyutil -p ...bounce) still works
// for the audio-cut-without-disconnect symptom where the user is willing to
// trigger it explicitly.
static const BOOL   kBounceOnConnect  = NO;
static const double kBounceOnConnectDelaySec = 2.0;

// After auto-reconnect, automatically resume music playback if it was playing
// before the drop. This is the real disconnect-mitigation deliverable: the
// drop still happens (we can't stop it — BTServer is unreachable on this
// jailbreak), but to the user it looks like "music briefly stops and comes
// back on its own" instead of "music dies and I have to manually tap play".
static const BOOL   kAutoResumePlayback        = YES;
static const double kResumePlaybackDelaySec    = 2.0;  // give A2DP route a beat
// Don't try to resume if the drop happened too long ago — user probably moved
// on. Anything beyond ~30s, assume they don't want surprise audio.
static const double kResumeMaxStaleSec         = 30.0;

// ---- BluetoothManager.framework (private, stable across iOS versions) ------
@interface BluetoothDevice : NSObject
- (NSString *)name;
- (NSString *)address;
- (BOOL)connected;
- (BOOL)paired;
- (void)connect;
- (void)connectWithServices:(unsigned int)services;
- (void)disconnect;
- (int)batteryLevel;
- (NSArray *)connectedServices;
- (unsigned int)connectedServicesCount;
- (id)getServiceSetting:(unsigned int)svc key:(id)key;
- (BOOL)setServiceSetting:(unsigned int)svc key:(id)key value:(id)val;
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

// ---- SpringBoard media controller (resume music after auto-reconnect) ------
@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (BOOL)isRingerMuted;
- (BOOL)play;
- (BOOL)pause;
- (BOOL)togglePlayPause;
- (id)nowPlayingApplication;
@end

// True if music was playing the last time AirPods dropped (so we know whether
// to resume after the auto-reconnect succeeds). Reset to NO when we resume,
// when the drop becomes stale, or when no music was playing at drop time.
static BOOL    gWasPlayingAtLastDrop = NO;
static NSDate *gLastDropAt = nil;

static void rememberPlaybackStateOnDrop(NSString *why) {
    if (!kAutoResumePlayback) return;
    @try {
        Class C = objc_getClass("SBMediaController");
        if (!C) { AFLog(@"[resume] SBMediaController missing (%@)", why); return; }
        id mc = [C sharedInstance];
        BOOL playing = [mc respondsToSelector:@selector(isPlaying)] && [mc isPlaying];
        gWasPlayingAtLastDrop = playing;
        gLastDropAt = [NSDate date];
        AFLog(@"[resume] remembered isPlaying=%d (%@)", playing, why);
    } @catch (NSException *e) {
        AFLog(@"[resume][EXC remember] %@ %@", e.name, e.reason);
    }
}

static void tryResumePlayback(NSString *why) {
    if (!kAutoResumePlayback) return;
    @try {
        if (!gWasPlayingAtLastDrop) {
            AFLog(@"[resume] nothing was playing at last drop — skip (%@)", why);
            return;
        }
        if (!gLastDropAt ||
            [[NSDate date] timeIntervalSinceDate:gLastDropAt] > kResumeMaxStaleSec) {
            AFLog(@"[resume] last drop too stale — skip (%@)", why);
            gWasPlayingAtLastDrop = NO;
            return;
        }
        Class C = objc_getClass("SBMediaController");
        if (!C) { AFLog(@"[resume] SBMediaController missing (%@)", why); return; }
        id mc = [C sharedInstance];
        if (![mc respondsToSelector:@selector(play)]) {
            AFLog(@"[resume] no -play selector"); return;
        }
        if ([mc respondsToSelector:@selector(isPlaying)] && [mc isPlaying]) {
            AFLog(@"[resume] already playing — clear flag (%@)", why);
            gWasPlayingAtLastDrop = NO;
            return;
        }
        AFLog(@"[resume] issuing -play (%@)", why);
        [mc play];
        gWasPlayingAtLastDrop = NO;
    } @catch (NSException *e) {
        AFLog(@"[resume][EXC try] %@ %@", e.name, e.reason);
    }
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

// ---- Auto route-heal (THE skip/pause + system-sound fix) -------------------
// The proven manual cure for the iOS-6 A2DP routing bug is the Control Center
// route flip back to the AirPods. We automate exactly that. The catch found in
// earlier diagnostics: outside a route-picker UI, MPAudioDeviceController in
// SpringBoard is blind — numberOfAudioRoutes returns 1 with a nil name, so the
// AirPods aren't a pickable indexed route. A live MPVolumeView activates the
// same AirPlay route discovery the Control Center route sheet uses, which makes
// the AirPods enumerate as a real indexed route we can pick. We mount one in a
// hidden, offscreen, non-interactive window so it stays invisible.
static UIWindow *gRouteWin = nil;
static id        gVolView  = nil;
static void ensureRouteDiscovery(void) {
    if (gRouteWin) return;
    @try {
        Class VV = objc_getClass("MPVolumeView");
        if (!VV) { AFLog(@"[heal] MPVolumeView class missing"); return; }
        gRouteWin = [[UIWindow alloc] initWithFrame:CGRectMake(-1000, -1000, 8, 8)];
        gRouteWin.windowLevel = 0;
        gRouteWin.userInteractionEnabled = NO;
        gRouteWin.backgroundColor = [UIColor clearColor];
        gVolView = [[VV alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
        [gRouteWin addSubview:gVolView];
        gRouteWin.hidden = NO;   // must be live in a window hierarchy for discovery
        AFLog(@"[heal] route-discovery volume view mounted (offscreen)");
    } @catch (NSException *e) { AFLog(@"[heal][EXC mount] %@ %@", e.name, e.reason); }
}

// Snapshot of what the route picker sees — the diagnostic that tells us whether
// the MPVolumeView trick populated the list (nRoutes>1) and what's picked.
static void logADCRoutes(NSString *tag) {
    @try {
        MPAudioDeviceController *adc = audioController();
        if (!adc) { AFLog(@"[adc][%@] no controller", tag); return; }
        BOOL wp = [adc respondsToSelector:@selector(wirelessRouteIsPicked)] && [adc wirelessRouteIsPicked];
        BOOL sp = [adc respondsToSelector:@selector(speakerRouteIsPicked)] && [adc speakerRouteIsPicked];
        BOOL extra = [adc respondsToSelector:@selector(routeOtherThanHandsetAndSpeakerIsAvailable)]
                     && [adc routeOtherThanHandsetAndSpeakerIsAvailable];
        AFLog(@"[adc][%@] nRoutes=%u picked=%@ wirelessPicked=%d speakerPicked=%d extraAvail=%d",
              tag, [adc numberOfAudioRoutes],
              [adc respondsToSelector:@selector(nameOfPickedRoute)] ? [adc nameOfPickedRoute] : @"?",
              wp, sp, extra);
        for (unsigned int i = 0; i < [adc numberOfAudioRoutes]; i++) {
            BOOL picked = NO;
            NSString *name = [adc routeNameAtIndex:i isPicked:&picked];
            AFLog(@"[adc][%@] [%u] name=%@ picked=%d", tag, i, name, picked);
        }
    } @catch (NSException *e) { AFLog(@"[adc][EXC] %@ %@", e.name, e.reason); }
}

// Re-pick the AirPods route IFF audio has drifted off them. This ONLY ever picks
// the AirPods (matched by name) — never the speaker — so it is structurally
// incapable of stranding audio on the speaker (the v2.7.11 regression that broke
// every previous attempt). No-op if already on the AirPods, or if the route list
// hasn't populated yet.
static void healRoute(NSString *why) {
    @try {
        MPAudioDeviceController *adc = audioController();
        if (!adc) return;
        unsigned int n = [adc numberOfAudioRoutes];
        if (n <= 1) return;                          // list not populated — nothing pickable
        int idx = routeIndexMatching(adc, @"airpod");
        if (idx < 0) return;                         // AirPods not enumerated — can't/won't act
        BOOL picked = NO;
        [adc routeNameAtIndex:(unsigned int)idx isPicked:&picked];
        if (picked) return;                          // already on AirPods — nothing to do
        AFLog(@"[heal] audio drifted off AirPods — re-picking route idx=%d (%@)", idx, why);
        [adc pickRouteAtIndex:(unsigned int)idx];
    } @catch (NSException *e) { AFLog(@"[heal][EXC] %@ %@", e.name, e.reason); }
}

// Heal loop. Runs in the media app for the life of the process; generation-gated
// (startHeal bumps the gen; each tick reschedules only while its gen is current)
// so calling startHeal twice can't spawn two loops, and stopHeal can orphan it.
// Every tick: keep discovery alive, log the picker's view, and heal if drifted.
static int gHealGen = 0;
static const double kHealTickSec = 2.5;   // re-pick within ~2.5s of a skip/pause

static void healTick(int gen) {
    if (gen != gHealGen) return;
    @try {
        ensureRouteDiscovery();
        MPAudioDeviceController *adc = audioController();
        if (adc) {
            // If the list still hasn't populated, kick a fresh discovery cycle.
            if ([adc numberOfAudioRoutes] <= 1) {
                if ([adc respondsToSelector:@selector(clearCachedRoutes)]) [adc clearCachedRoutes];
                if ([adc respondsToSelector:@selector(setRouteDiscoveryEnabled:)]) [adc setRouteDiscoveryEnabled:YES];
            }
            logADCRoutes(@"heal");
            healRoute(@"heal");
        }
    } @catch (NSException *e) { AFLog(@"[heal][EXC tick] %@ %@", e.name, e.reason); }
    if (gen != gHealGen) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHealTickSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ healTick(gen); });
}

static void startHeal(NSString *why) {
    int gen = ++gHealGen;
    AFLog(@"[heal] START (%@) — re-pick AirPods route if it drifts, every %.1fs", why, kHealTickSec);
    // Mount discovery immediately (on main) so the list is populating before the
    // first tick fires.
    ensureRouteDiscovery();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHealTickSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ healTick(gen); });
}

static void stopHeal(NSString *why) {
    if (gHealGen == 0) return;
    gHealGen++;   // orphan the pending tick
    AFLog(@"[heal] STOP (%@)", why);
}

// One step of the bounce. wantAirPods=NO -> pick speaker; wantAirPods=YES ->
// restore the previously-picked route (the AirPods, since we just switched away
// from them). Reschedules itself for `remaining` more steps with the opposite
// target, ending on AirPods.
//
// We use -restorePickedRoute (an MPAudioDeviceController API explicitly built
// for "go back to what was picked before") rather than pickRouteAtIndex:N,
// because on iOS 6 the indexed route list only populates when a route-picker
// UI is mounted — outside that context, numberOfAudioRoutes returns 1 with a
// nil name even when wireless routes are clearly available
// (routeOtherThanHandsetAndSpeakerIsAvailable=YES). restorePickedRoute works
// without that UI context.
static void bounceStep(int remaining, BOOL wantAirPods) {
    @try {
        MPAudioDeviceController *adc = audioController();
        if (!adc) return;
        if (wantAirPods) {
            AFLog(@"[route] step rem=%d -> restore (AirPods)", remaining);
            if ([adc respondsToSelector:@selector(restorePickedRoute)]) {
                [adc restorePickedRoute];
            } else {
                // Fallback: by-name index lookup if it happens to be populated.
                int idx = routeIndexMatching(adc, @"airpod");
                if (idx >= 0) [adc pickRouteAtIndex:(unsigned int)idx];
            }
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
        // Gate the bounce on "is there a wireless / non-handset-non-speaker route
        // available" — this returns YES even when the indexed route list is
        // empty (which is normal outside a route-picker UI context). If no
        // external route exists at all, bouncing to speaker would lose audio.
        BOOL extra = [a respondsToSelector:@selector(routeOtherThanHandsetAndSpeakerIsAvailable)]
                     && [a routeOtherThanHandsetAndSpeakerIsAvailable];
        BOOL wirelessPicked = [a respondsToSelector:@selector(wirelessRouteIsPicked)]
                              && [a wirelessRouteIsPicked];
        if (!extra && !wirelessPicked) {
            AFLog(@"[route] no external route available — skipping bounce (%@)", why);
            return;
        }
        AFLog(@"[route] bounce start (%@): speaker<->restorePicked x%d (extra=%d wireless=%d)",
              why, kBounceRepeats, extra, wirelessPicked);
        // Start at speaker (NO), bounce 2*repeats-1 more times so we END on
        // restored (AirPods).
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

// Pre-emptive service re-assert. Fires every kPreemptIntervalSec while AirPods
// are connected, so a re-assert always lands a few seconds before the ~45s
// firmware teardown. Unlike the old gentle poke (which only READ battery/state
// and did nothing to the link), this actively calls -connectWithServices: on the
// live device to re-run the service-connect path — the strongest host-side
// action short of a full reconnect.
//
// CRITICAL: never retain a BluetoothDevice across time. The wrapper holds a raw
// pointer to a daemon-side device struct; retaining the ObjC object does NOT
// keep that struct alive, so poking a stale device later is a dangling-pointer
// crash (SIGSEGV — uncatchable by @try, this is what was crashing SpringBoard).
// So we re-fetch the live connectedDevices fresh on every single tick.
//
// Generation-gated: startPreempt() bumps gPreemptGen and seeds a tick carrying
// that gen; each tick reschedules itself only while its gen is still current.
// A disconnect (stopPreempt) bumps the gen, orphaning any pending tick.
static int gPreemptGen = 0;

static void preemptTick(int gen) {
    if (gen != gPreemptGen) return;  // superseded by a newer connect/disconnect
    @try {
        Class mgrC = objc_getClass("BluetoothManager");
        BluetoothManager *m = mgrC ? [mgrC sharedInstance] : nil;
        NSArray *devs = [m respondsToSelector:@selector(connectedDevices)] ? [m connectedDevices] : nil;
        BOOL acted = NO;
        for (BluetoothDevice *d in devs) {
            if (!deviceLooksLikeAirPods(d)) continue;
            if (![d respondsToSelector:@selector(connected)] || ![d connected]) continue;
            if ([d respondsToSelector:@selector(connectWithServices:)]) {
                AFLog(@"[SpringBoard][preempt] RE-ASSERT connectWithServices:~0 on %@ (before ~45s drop)", [d name]);
                [d connectWithServices:(unsigned int)~0u];
                acted = YES;
            }
        }
        if (!acted) AFLog(@"[SpringBoard][preempt] skip (no connected AirPods right now)");
    } @catch (NSException *e) {
        AFLog(@"[SpringBoard][preempt][EXC] %@ %@", e.name, e.reason);
    }
    if (gen != gPreemptGen) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPreemptIntervalSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ preemptTick(gen); });
}

static void startPreempt(NSString *why) {
    int gen = ++gPreemptGen;  // invalidate any previous schedule, start fresh
    AFLog(@"[SpringBoard][preempt] START (%@) — re-assert every %.0fs", why, kPreemptIntervalSec);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPreemptIntervalSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ preemptTick(gen); });
}

static void stopPreempt(NSString *why) {
    if (gPreemptGen == 0) return;
    gPreemptGen++;  // orphans the pending tick
    AFLog(@"[SpringBoard][preempt] STOP (%@)", why);
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

// BluetoothManager fires its disconnect notification twice in a row for a
// single physical drop on this stack. Dedupe within a short window so we don't
// double-fire the burst (harmless but noisy).
static NSDate *gLastDisconnectAt = nil;
static NSString *gLastDisconnectAddr = nil;
static const double kDedupeWindowSec = 0.5;

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
    NSString *key = addr ?: name;
    if (gLastDisconnectAt && [gLastDisconnectAddr isEqualToString:key] &&
        [[NSDate date] timeIntervalSinceDate:gLastDisconnectAt] < kDedupeWindowSec) {
        AFLog(@"[SpringBoard][mitigation] dup disconnect for %@ inside %.1fs — skip", name, kDedupeWindowSec);
        return;
    }
    gLastDisconnectAt = [NSDate date];
    gLastDisconnectAddr = key;
    // Capture whether music was playing BEFORE we wait — iOS may auto-pause the
    // session as soon as the A2DP route goes away, so we want the state from
    // before that happens (this handler fires very fast after the drop).
    rememberPlaybackStateOnDrop([NSString stringWithFormat:@"AirPods drop: %@", name]);
    if (!underRateLimit(addr ?: name)) {
        AFLog(@"[SpringBoard][mitigation] rate limit hit for %@ — backing off", name);
        return;
    }
    AFLog(@"[SpringBoard][mitigation] BURST reconnect for %@ at %d offsets", name, kBurstCount);
    // Fire connect attempts back-to-back so at least one lands inside iOS's
    // audio-session-keepalive window. Each attempt no-ops cleanly if the device
    // is already back by then.
    for (int i = 0; i < kBurstCount; i++) {
        double offset = kBurstDelaysSec[i];
        int idx = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(offset * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if ([dev respondsToSelector:@selector(connected)] && [dev connected]) {
                    AFLog(@"[SpringBoard][mitigation] %@ already back at burst[%d] — skip", name, idx);
                    return;
                }
                // Prefer connectWithServices: when available — reactivates the
                // specific A2DP service vs a full pairing handshake. Pass ~0
                // (all services) so we get HFP back too if it was up.
                if ([dev respondsToSelector:@selector(connectWithServices:)]) {
                    AFLog(@"[SpringBoard][mitigation] burst[%d] -connectWithServices:~0 on %@", idx, name);
                    [dev connectWithServices:(unsigned int)~0u];
                } else if ([dev respondsToSelector:@selector(connect)]) {
                    AFLog(@"[SpringBoard][mitigation] burst[%d] -connect on %@", idx, name);
                    [dev connect];
                }
            } @catch (NSException *e) {
                AFLog(@"[SpringBoard][EXC] reconnect %@ burst[%d]: %@ %@", name, idx, e.name, e.reason);
            }
        });
    }
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

    // One-shot dump of every BT preferences plist we can find on disk, so we
    // can see what -setServiceSetting:key:value: keys actually exist for this
    // device (and which one might let us prevent the disconnect entirely).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSArray *paths = @[
            @"/var/preferences/SystemConfiguration/com.apple.MobileBluetooth.devices.plist",
            @"/var/preferences/SystemConfiguration/com.apple.MobileBluetooth.services.plist",
            @"/var/wireless/Library/Preferences/com.apple.MobileBluetooth.devices.plist",
            @"/var/wireless/Library/Preferences/com.apple.MobileBluetooth.services.plist",
            @"/var/mobile/Library/Preferences/com.apple.MobileBluetooth.plist",
            @"/var/mobile/Library/Preferences/com.apple.Bluetooth.plist",
            @"/Library/Preferences/com.apple.MobileBluetooth.devices.plist",
            @"/Library/Preferences/com.apple.MobileBluetooth.services.plist",
        ];
        for (NSString *p in paths) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
            @try {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
                if (!d) { AFLog(@"[btprefs] %@ — exists but not a plist dict", p); continue; }
                AFLog(@"[btprefs] %@ keys=%@", p, [d allKeys]);
                // Devices plist usually maps MAC string -> per-device dict. Log
                // the AirPods entry in full if we can spot it.
                for (NSString *k in d) {
                    id v = d[k];
                    if (![v isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *dev = (NSDictionary *)v;
                    NSString *nm = dev[@"Name"] ?: dev[@"name"];
                    if (!strHas(nm, @"airpod") && ![k hasPrefix:@"14:14:7D"]) continue;
                    AFLog(@"[btprefs] device %@ (%@) keys=%@", k, nm, [dev allKeys]);
                    for (NSString *dk in dev) {
                        AFLog(@"[btprefs] %@.%@ = %@", k, dk, dev[dk]);
                    }
                }
            } @catch (NSException *e) {
                AFLog(@"[btprefs][EXC] %@: %@", p, e.reason);
            }
        }
    });

    // Also probe -getServiceSetting:key: on the device with common candidate
    // keys, so we can see which ones return non-nil (= are real). Fires once
    // when we first see a connected AirPods device.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            Class mgr = objc_getClass("BluetoothManager");
            BluetoothManager *m = [mgr sharedInstance];
            for (BluetoothDevice *d in [m connectedDevices]) {
                if (!deviceLooksLikeAirPods(d)) continue;
                if (![d respondsToSelector:@selector(getServiceSetting:key:)]) continue;
                NSArray *keys = @[
                    @"AutoConnect", @"PreferredConnections", @"SupportsBatteryLevel",
                    @"AudioCategory", @"DeviceClass", @"Connectable",
                    @"SupervisionTimeout", @"LinkPolicy", @"LinkSupervisionTimeout",
                    @"SniffMode", @"SniffInterval", @"PowerSave",
                    @"ServiceClass", @"PreferredServices", @"DefaultServices",
                    @"RoleSwitchAllowed", @"AuthRequired",
                ];
                for (unsigned int svc = 0; svc < 8; svc++) {
                    for (NSString *k in keys) {
                        id v = nil;
                        @try { v = [d getServiceSetting:svc key:k]; } @catch (NSException *e) {}
                        if (v) AFLog(@"[btsetting] svc=%u key=%@ = %@", svc, k, v);
                    }
                }
            }
        } @catch (NSException *e) {
            AFLog(@"[btsetting][EXC] %@ %@", e.name, e.reason);
        }
    });

    // These notification names are posted by BluetoothManager. We register for
    // a generous set so we capture whatever this iOS build actually fires.
    observe(@"BluetoothDeviceDisconnectSuccessNotification", @"disconnect", ^(NSNotification *n) {
        BluetoothDevice *d = (BluetoothDevice *)n.object;
        if (deviceLooksLikeAirPods(d)) stopPreempt(@"AirPods disconnect");
        handleDisconnect(d, n.userInfo);
    });
    observe(@"BluetoothDeviceConnectSuccessNotification", @"connect", ^(NSNotification *n) {
        if (!deviceLooksLikeAirPods((BluetoothDevice *)n.object)) return;
        // Pre-emption experiment: re-assert the service connection a few seconds
        // before the firmware's ~45s teardown, anchored to this connect.
        startPreempt(@"AirPods connect");
        if (kBounceOnConnect) {
            scheduleRouteReset(@"post-connect");
        }
        // Safety net: if a drop happens anyway, resume any music that was
        // playing before. Internally rate-limited (no-op if nothing to resume).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kResumePlaybackDelaySec * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ tryResumePlayback(@"post-connect"); });
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

    // The pre-empt loop is anchored to each connect (startPreempt in the connect
    // observer + the startup snapshot below), not kicked off here, so a re-assert
    // always lands relative to when the link actually came up.

    // One-shot snapshot of what's currently connected, for context in the logs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class mgr = objc_getClass("BluetoothManager");
        if (!mgr) { AFLog(@"[SpringBoard] BluetoothManager class not found"); return; }
        BluetoothManager *m = [mgr sharedInstance];
        AFLog(@"[SpringBoard] snapshot connectedDevices=%@", [m connectedDevices]);
        // If AirPods are already connected at SpringBoard load (e.g. respring
        // while still wearing them), start the pre-empt re-assert loop now.
        for (BluetoothDevice *d in [m connectedDevices]) {
            if (deviceLooksLikeAirPods(d)) {
                startPreempt(@"already-connected at startup");
                break;
            }
        }

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
                // Injected into the media app (per the filter — com.apple.mobileipod
                // / Music). SpringBoard's MPAudioDeviceController is blind
                // (nRoutes=1, confirmed), but the process that actually OWNS the
                // audio session has live AirPlay route discovery — so the AirPods
                // should enumerate as a pickable indexed route here. Run the heal
                // loop in-process: log what the picker sees, and re-pick the
                // AirPods route if media audio has drifted off them after a
                // skip/pause (only ever picks AirPods — never the speaker).
                AFLog(@"[media] route-heal scheduled in %@", proc);
                // Defer past launch so UIApplication exists before we mount the
                // route-discovery window (creating a UIWindow at %ctor is too early).
                NSString *p = proc;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    startHeal([NSString stringWithFormat:@"media app %@", p]);
                });
            }
        } @catch (NSException *e) {
            // Critically, never crash the BT daemon or SpringBoard at load.
            AFLog(@"[ctor][EXC] %@ in %@: %@", e.name, proc, e.reason);
        }
    }
}
