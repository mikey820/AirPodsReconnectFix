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
// Runs as root from the package's maintainer scripts.

#import <Foundation/Foundation.h>
#import <stdio.h>

static NSString *const kPlist  = @"/System/Library/LaunchDaemons/com.apple.BTServer.plist";
static NSString *const kDir    = @"/Library/AirPodsReconnectFix";
static NSString *const kBackup = @"/Library/AirPodsReconnectFix/BTServer.plist.orig";
static NSString *const kDylib  = @"/Library/MobileSubstrate/DynamicLibraries/AirPodsReconnectFix.dylib";

static int doInstall(NSFileManager *fm) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPlist];
    if (!d) { fprintf(stderr, "aprfctl: cannot read %s\n", kPlist.UTF8String); return 1; }

    // Back up the pristine original exactly once.
    [fm createDirectoryAtPath:kDir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm fileExistsAtPath:kBackup]) {
        if (![fm copyItemAtPath:kPlist toPath:kBackup error:nil]) {
            fprintf(stderr, "aprfctl: backup failed; refusing to patch\n");
            return 1;
        }
    }

    NSMutableDictionary *env = [[d objectForKey:@"EnvironmentVariables"] mutableCopy];
    if (!env) env = [NSMutableDictionary dictionary];
    [env setObject:kDylib forKey:@"DYLD_INSERT_LIBRARIES"];
    [d setObject:env forKey:@"EnvironmentVariables"];

    if (![d writeToFile:kPlist atomically:YES]) {
        fprintf(stderr, "aprfctl: write failed\n");
        return 1;
    }
    printf("aprfctl: patched (DYLD_INSERT_LIBRARIES -> %s)\n", kDylib.UTF8String);
    return 0;
}

static int doUninstall(NSFileManager *fm) {
    if ([fm fileExistsAtPath:kBackup]) {
        [fm removeItemAtPath:kPlist error:nil];
        if (![fm copyItemAtPath:kBackup toPath:kPlist error:nil]) {
            fprintf(stderr, "aprfctl: RESTORE FAILED — copy %s over %s in Filza\n",
                    kBackup.UTF8String, kPlist.UTF8String);
            return 1;
        }
        [fm removeItemAtPath:kBackup error:nil];
        printf("aprfctl: restored original BTServer.plist\n");
        return 0;
    }
    // No backup: best-effort strip of just our key.
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:kPlist];
    if (!d) { fprintf(stderr, "aprfctl: cannot read plist to strip\n"); return 1; }
    NSMutableDictionary *env = [[d objectForKey:@"EnvironmentVariables"] mutableCopy];
    if (env && [env objectForKey:@"DYLD_INSERT_LIBRARIES"]) {
        [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
        if (env.count) [d setObject:env forKey:@"EnvironmentVariables"];
        else           [d removeObjectForKey:@"EnvironmentVariables"];
        [d writeToFile:kPlist atomically:YES];
    }
    printf("aprfctl: stripped our env key (no backup found)\n");
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
