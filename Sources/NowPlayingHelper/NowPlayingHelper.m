#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include "NowPlayingHelper.h"

typedef void (*GetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetAppID)(dispatch_queue_t, void (^)(CFStringRef));
typedef void (*RegisterForNotifications)(dispatch_queue_t);
typedef Boolean (*SendCommand)(int, CFDictionaryRef);

static GetInfo getInfo;
static GetIsPlaying getIsPlaying;
static GetAppID getAppID;
static SendCommand sendCommand;

static NSString *lastLine;
static BOOL refreshScheduled;
static dispatch_source_t commandSource;

/// Writes the state as a line of JSON, unless it is the line written last.
static void emit(NSDictionary *state) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine]) return;
    lastLine = line;
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static void copyString(NSDictionary *info, NSString *key, NSMutableDictionary *state, NSString *name) {
    id value = info[key];
    if ([value isKindOfClass:NSString.class] && [value length] > 0) state[name] = value;
}

/// Reads the track, whether it plays, and the app playing it, and reports them. A change
/// usually comes as several notifications at once, so they are gathered into one read.
static void refresh(void) {
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_queue_t main = dispatch_get_main_queue();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), main, ^{
        refreshScheduled = NO;
        getInfo(main, ^(CFDictionaryRef infoRef) {
            NSDictionary *info = (__bridge NSDictionary *)infoRef;
            NSMutableDictionary *state = [NSMutableDictionary dictionary];
            copyString(info, @"kMRMediaRemoteNowPlayingInfoTitle", state, @"title");
            copyString(info, @"kMRMediaRemoteNowPlayingInfoArtist", state, @"artist");
            copyString(info, @"kMRMediaRemoteNowPlayingInfoAlbum", state, @"album");
            getIsPlaying(main, ^(Boolean playing) {
                state[@"playing"] = playing ? @YES : @NO;
                getAppID(main, ^(CFStringRef app) {
                    if (app) state[@"app"] = (__bridge NSString *)app;
                    emit(state);
                });
            });
        });
    });
}

/// Sends each command number read from standard input. Exits when standard input closes,
/// which is when the app that started this process has quit or crashed.
static void readCommands(void) {
    static char buffer[256];
    static size_t used;
    commandSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(commandSource, ^{
        ssize_t count = read(STDIN_FILENO, buffer + used, sizeof buffer - used - 1);
        if (count <= 0) exit(0);
        used += (size_t)count;
        char *start = buffer;
        char *newline;
        while ((newline = memchr(start, '\n', (size_t)(buffer + used - start)))) {
            *newline = 0;
            sendCommand(atoi(start), NULL);
            start = newline + 1;
        }
        used = (size_t)(buffer + used - start);
        memmove(buffer, start, used);
        if (used == sizeof buffer - 1) used = 0;
    });
    dispatch_resume(commandSource);
}

void gooey_now_playing_run(void) {
    void *mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!mediaRemote) exit(2);
    getInfo = (GetInfo)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (GetIsPlaying)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getAppID = (GetAppID)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationDisplayID");
    sendCommand = (SendCommand)dlsym(mediaRemote, "MRMediaRemoteSendCommand");
    RegisterForNotifications registerForNotifications = (RegisterForNotifications)dlsym(mediaRemote, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getAppID || !sendCommand || !registerForNotifications) exit(2);

    registerForNotifications(dispatch_get_main_queue());
    const char *names[] = {
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    };
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        CFStringRef *name = (CFStringRef *)dlsym(mediaRemote, names[i]);
        if (!name) continue;
        [NSNotificationCenter.defaultCenter addObserverForName:(__bridge NSString *)*name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            refresh();
        }];
    }

    readCommands();
    refresh();
    CFRunLoopRun();
    exit(0);
}
