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

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([cmd isEqualToString:@"install"])   return doInstall(fm);
        if ([cmd isEqualToString:@"uninstall"]) return doUninstall(fm);
        fprintf(stderr, "usage: aprfctl install|uninstall\n");
        return 2;
    }
}
