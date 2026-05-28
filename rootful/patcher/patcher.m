// aprfctl — patches /System/Library/LaunchDaemons/com.apple.BTServer.plist to
// force-load our dylib into BTServer via DYLD_INSERT_LIBRARIES. MobileSubstrate
// refuses to inject into BTServer on iOS 6, so this is the only way in.
//
// In-place MERGE: we read the existing plist, add ONLY the one env key, and
// write it back — every other key (ProgramArguments, KeepAlive, MachServices,
// UserName, …) is preserved. A one-time backup is kept so uninstall fully
// restores the original.
//
//   aprfctl install     add the DYLD_INSERT_LIBRARIES env var (+ backup once)
//   aprfctl uninstall   restore the backup (or strip our key if no backup)
//
// Runs as root from the package's maintainer scripts. Every step is logged to
// /var/mobile/AirPodsReconnectFix.log (same file the tweak uses) WITH the real
// write error, so a failed patch is diagnosable from the log instead of silent.

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <stdio.h>

static NSString *const kPlist  = @"/System/Library/LaunchDaemons/com.apple.BTServer.plist";
static NSString *const kDir    = @"/Library/AirPodsReconnectFix";
static NSString *const kBackup = @"/Library/AirPodsReconnectFix/BTServer.plist.orig";
static NSString *const kDylib  = @"/Library/MobileSubstrate/DynamicLibraries/AirPodsReconnectFix.dylib";
static NSString *const kLog    = @"/var/mobile/AirPodsReconnectFix.log";

static void plog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [aprfctl] %@\n", [NSDate date], msg];
    FILE *f = fopen(kLog.fileSystemRepresentation, "a");
    if (f) { fputs(line.UTF8String, f); fclose(f); chmod(kLog.fileSystemRepresentation, 0666); }
    fprintf(stderr, "%s", line.UTF8String);
}

// Write a dict back as a binary plist, capturing a real error string.
static BOOL writePlist(NSDictionary *d, NSString *path) {
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:d
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&err];
    if (!data) { plog(@"serialize FAILED: %@", err); return NO; }
    if (![data writeToFile:path options:NSDataWritingAtomic error:&err]) {
        plog(@"write %@ FAILED: %@", path, err);
        return NO;
    }
    chmod(path.fileSystemRepresentation, 0644);
    return YES;
}

static int doInstall(NSFileManager *fm) {
    plog(@"install: start");
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPlist];
    if (!d) { plog(@"install: cannot read %@", kPlist); return 1; }

    [fm createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:kBackup]) {
        NSError *e = nil;
        if (![fm copyItemAtPath:kPlist toPath:kBackup error:&e]) {
            plog(@"install: backup FAILED: %@ — refusing to patch", e);
            return 1;
        }
        plog(@"install: backed up original to %@", kBackup);
    }

    NSMutableDictionary *env = [[d objectForKey:@"EnvironmentVariables"] mutableCopy];
    if (!env) env = [NSMutableDictionary dictionary];
    [env setObject:kDylib forKey:@"DYLD_INSERT_LIBRARIES"];
    [d setObject:env forKey:@"EnvironmentVariables"];

    if (!writePlist(d, kPlist)) return 1;
    plog(@"install: DONE — patched %@", kPlist);
    return 0;
}

static int doUninstall(NSFileManager *fm) {
    plog(@"uninstall: start");
    if ([fm fileExistsAtPath:kBackup]) {
        NSError *e = nil;
        [fm removeItemAtPath:kPlist error:nil];
        if (![fm copyItemAtPath:kBackup toPath:kPlist error:&e]) {
            plog(@"uninstall: RESTORE FAILED: %@ — copy %@ over %@ in Filza", e, kBackup, kPlist);
            return 1;
        }
        chmod(kPlist.fileSystemRepresentation, 0644);
        [fm removeItemAtPath:kBackup error:nil];
        plog(@"uninstall: restored original from backup");
        return 0;
    }
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPlist];
    if (!d) { plog(@"uninstall: cannot read plist to strip"); return 1; }
    NSMutableDictionary *env = [[d objectForKey:@"EnvironmentVariables"] mutableCopy];
    if (env && [env objectForKey:@"DYLD_INSERT_LIBRARIES"]) {
        [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
        if (env.count) [d setObject:env forKey:@"EnvironmentVariables"];
        else           [d removeObjectForKey:@"EnvironmentVariables"];
        writePlist(d, kPlist);
    }
    plog(@"uninstall: stripped our env key (no backup found)");
    return 0;
}

// scan-bt: as root, hunt for every Bluetooth preferences plist on disk and dump
// its contents to the log so we can see what per-device keys actually exist.
// SpringBoard runs as `mobile`, which can't read /var/wireless/ — so this
// discovery has to happen here. Searches /var and /Library recursively, filters
// for files matching *Bluetooth*.plist (case-insensitive). For any dict-valued
// entry that mentions an AirPods name or the user's MAC, every key/value is
// logged so v2.7.8 can target the right setting via -setServiceSetting:key:value:.
static void scanDir(NSString *root, NSFileManager *fm, NSMutableArray *out) {
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSString *sub;
    while ((sub = [en nextObject])) {
        // Skip giant uninteresting trees to keep this snappy.
        if ([sub hasPrefix:@"mobile/Containers"] ||
            [sub hasPrefix:@"mobile/Media"] ||
            [sub hasPrefix:@"mobile/Applications"] ||
            [sub hasPrefix:@"db/timezone"] ||
            [sub hasPrefix:@"db/dyld"] ||
            [sub hasPrefix:@"logs"]) { [en skipDescendents]; continue; }
        NSString *low = [sub.lowercaseString lastPathComponent];
        if (![low hasSuffix:@".plist"]) continue;
        if ([low rangeOfString:@"bluetooth"].location == NSNotFound) continue;
        [out addObject:[root stringByAppendingPathComponent:sub]];
    }
}

static int doScanBT(NSFileManager *fm) {
    plog(@"scan-bt: start");
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *root in @[ @"/var", @"/Library", @"/private/var" ]) {
        if (![fm fileExistsAtPath:root]) continue;
        @try { scanDir(root, fm, hits); }
        @catch (NSException *e) { plog(@"scan-bt: exception scanning %@: %@", root, e.reason); }
    }
    plog(@"scan-bt: found %u candidate plists", (unsigned)hits.count);
    for (NSString *path in hits) {
        @try {
            plog(@"scan-bt: %@", path);
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
            if (!d) { plog(@"scan-bt:   (not a dict-typed plist)"); continue; }
            plog(@"scan-bt:   top keys=%@", [d allKeys]);
            // If the file maps MAC->dict (devices/services plists), dump each
            // sub-dict in full so we see every per-device key.
            for (NSString *k in d) {
                id v = d[k];
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *sub = (NSDictionary *)v;
                NSString *nm = sub[@"Name"] ?: sub[@"name"] ?: @"";
                BOOL match = [nm.lowercaseString rangeOfString:@"airpod"].location != NSNotFound ||
                             [k.lowercaseString hasPrefix:@"14:14:7d"];
                if (!match) {
                    // Still log a one-liner so we know the shape of the file.
                    plog(@"scan-bt:     [%@] name=%@ keys=%@", k, nm, [sub allKeys]);
                    continue;
                }
                plog(@"scan-bt:   ** AirPods entry %@ (%@) **", k, nm);
                for (NSString *dk in sub) {
                    plog(@"scan-bt:     %@.%@ = %@", k, dk, sub[dk]);
                }
            }
        } @catch (NSException *e) {
            plog(@"scan-bt: read %@ failed: %@", path, e.reason);
        }
    }
    plog(@"scan-bt: done");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([cmd isEqualToString:@"install"])   return doInstall(fm);
        if ([cmd isEqualToString:@"uninstall"]) return doUninstall(fm);
        if ([cmd isEqualToString:@"scan-bt"])   return doScanBT(fm);
        fprintf(stderr, "usage: aprfctl install|uninstall|scan-bt\n");
        return 2;
    }
}
