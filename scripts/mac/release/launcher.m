// The executable of the Mac release app (scripts/mac/package_release.sh). The
// app carries the host and the recompiled game module, never game data: at
// the first launch it asks for the player's own disc image (GZLE01, USA
// revision 0) in an open panel, checks it, and prepares main.dol and the REL
// modules from it (apple/ios/src/disc_import.c, as the iPad app does) into
//
//   ~/Library/Application Support/Wind Waker Recomp/
//     disc.txt       where the disc image is (the game reads it while it runs)
//     game/          main.dol and rels/, prepared from that disc
//     GZLE01.card    the memory card; sram.bin, settings.ini, logs/
//
// with a progress window while it works, then runs the host with the
// environment a double-clicked app does not get. A compressed image (Dolphin's
// RVZ, WIA, GCZ, CISO and others) is first unpacked once, with nod, into a plain
// GZLE01.iso in that folder, which the game then reads. Dialogs are AppKit's
// own; nothing runs through AppleScript. A variable already set wins, so a
// terminal launch can override any of it.
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "disc_import.h"
#include "nod.h"

#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static NSString* const kTitle = @"Wind Waker Recomp";

static const char kDefaultSettings[] =
    "# Wind Waker Recomp settings, written by the options menu (Esc or F1 in the game).\n"
    "# KEY=VALUE, the host's environment settings.\n"
    "BLUEWAKE_ASPECT=16:10\n"
    "DOL_AURORA_FULLSCREEN=1\n"
    "DOL_AURORA_FRAME_INTERP=1\n"
    "DOL_AURORA_FRAME_INTERP_STEPS=1\n";

static int exists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0;
}

// `path` and any folders above it that are missing.
static void make_dirs(const char* path) {
    char partial[PATH_MAX];
    snprintf(partial, sizeof partial, "%s", path);
    for (char* p = partial + 1; *p != '\0'; ++p) {
        if (*p != '/')
            continue;
        *p = '\0';
        mkdir(partial, 0755);
        *p = '/';
    }
    mkdir(partial, 0755);
}

static int read_line(const char* file, char* out, size_t size) {
    FILE* f = fopen(file, "r");
    if (f == NULL)
        return 0;
    const int ok = fgets(out, (int)size, f) != NULL;
    fclose(f);
    if (!ok)
        return 0;
    size_t len = strlen(out);
    while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r'))
        out[--len] = '\0';
    return len > 0;
}

static void write_text(const char* file, const char* text) {
    FILE* f = fopen(file, "w");
    if (f == NULL)
        return;
    fputs(text, f);
    fclose(f);
}

// --- AppKit ---------------------------------------------------------------

// Made only when there is something to show: a launch with the disc already
// prepared goes straight to the game.
static void ensure_app(void) {
    static BOOL made = NO;
    if (made)
        return;
    made = YES;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    [NSApp activate];
}

static void show_alert(NSString* message, NSString* detail, BOOL error) {
    ensure_app();
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = detail ?: @"";
    alert.alertStyle = error ? NSAlertStyleCritical : NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activate];
    [alert runModal];
}

// The player's disc image, from an open panel; nil when cancelled.
static NSString* choose_disc(void) {
    ensure_app();
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = kTitle;
    panel.message = @"Choose your disc image of The Legend of Zelda: The Wind Waker (USA, GZLE01): .iso, "
                    @".gcm, or a Dolphin .rvz, .gcz, .wia or .ciso.";
    panel.prompt = @"Choose";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    for (NSString* extension in @[ @"iso", @"gcm", @"rvz", @"gcz", @"wia", @"ciso", @"nfs", @"tgc" ]) {
        UTType* type = [UTType typeWithFilenameExtension:extension];
        if (type != nil)
            [types addObject:type];
    }
    panel.allowedContentTypes = types;
    [NSApp activate];
    if ([panel runModal] != NSModalResponseOK || panel.URL == nil)
        return nil;
    return panel.URL.path;
}

// --- Preparing the disc, on a worker thread under a progress window --------

static _Atomic double g_fraction;   // 0 to 1 of the whole job
static _Atomic int g_stage;         // 0 unpacking, 1 preparing
static _Atomic int g_done;
static int g_result;
static char g_error[512];
static double g_prepare_from;       // where preparing starts in g_fraction

// A plain GameCube image: the disc magic at 0x1C.
static int is_plain_image(const char* path) {
    unsigned char header[0x20];
    FILE* f = fopen(path, "rb");
    if (f == NULL)
        return 0;
    const size_t got = fread(header, 1, sizeof header, f);
    fclose(f);
    return got == sizeof header && header[0x1C] == 0xC2 && header[0x1D] == 0x33 && header[0x1E] == 0x9F &&
           header[0x1F] == 0x3D;
}

// A compressed image unpacked into a plain one at `out`; 0 on success.
static int unpack_image(const char* in, const char* out, char* error, size_t error_size) {
    NodDiscOptions options = {0};
    options.preloader_threads = 4;
    NodHandle* disc = NULL;
    if (nod_disc_open(in, &options, &disc) != NOD_RESULT_OK) {
        const char* why = nod_error_message();
        snprintf(error, error_size,
                 "This file is not a GameCube disc image Wind Waker Recomp can read (%s). Choose a .iso, .gcm or "
                 "Dolphin .rvz, .gcz, .wia or .ciso image of your disc.",
                 why != NULL ? why : "unknown format");
        return -1;
    }
    NodDiscHeader header;
    if (nod_disc_header(disc, &header) != NOD_RESULT_OK || memcmp(header.game_id, "GZLE01", 6) != 0) {
        snprintf(error, error_size,
                 "This disc is not The Legend of Zelda: The Wind Waker for the USA (GZLE01). Its id is %.6s.",
                 header.game_id);
        nod_free(disc);
        return -1;
    }
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s.part", out);
    FILE* f = fopen(tmp, "wb");
    if (f == NULL) {
        snprintf(error, error_size, "Could not write %s (%s).", tmp, strerror(errno));
        nod_free(disc);
        return -1;
    }
    const uint64_t total = nod_disc_size(disc);
    static uint8_t buffer[8u << 20];
    uint64_t done = 0;
    int result = 0, last = -1;
    for (;;) {
        const int64_t n = nod_read(disc, buffer, sizeof buffer);
        if (n < 0) {
            const char* why = nod_error_message();
            snprintf(error, error_size, "Could not read the disc image (%s).", why != NULL ? why : "read error");
            result = -1;
            break;
        }
        if (n == 0)
            break;
        if (fwrite(buffer, 1, (size_t)n, f) != (size_t)n) {
            snprintf(error, error_size, "Could not write the unpacked disc image (%s).", strerror(errno));
            result = -1;
            break;
        }
        done += (uint64_t)n;
        const double part = total != 0 ? (double)done / (double)total : 0.0;
        atomic_store(&g_fraction, part * g_prepare_from);
        const int percent = (int)(part * 100.0);
        if (percent / 10 != last / 10)
            fprintf(stderr, "[app] unpacking the disc image: %d%%\n", percent);
        last = percent;
    }
    nod_free(disc);
    if (fclose(f) != 0 && result == 0) {
        snprintf(error, error_size, "Could not write the unpacked disc image (%s).", strerror(errno));
        result = -1;
    }
    if (result == 0 && rename(tmp, out) != 0) {
        snprintf(error, error_size, "Could not write %s (%s).", out, strerror(errno));
        result = -1;
    }
    if (result != 0)
        unlink(tmp);
    return result;
}

static void prepare_progress(void* context, double fraction, const char* stage) {
    (void)context;
    atomic_store(&g_fraction, g_prepare_from + fraction * (1.0 - g_prepare_from));
    fprintf(stderr, "[app] preparing the disc: %3.0f%% %s\n", fraction * 100.0, stage != NULL ? stage : "");
}

// The chosen image (unpacked first when compressed: `disc` then names the
// plain copy) prepared into `game`, under a progress window. 0 on success,
// else g_error says why.
static int prepare_disc(char* disc, size_t disc_size, const char* support, const char* game) {
    // The worker's paths, which a block cannot capture as arrays.
    static char source[PATH_MAX], plain[PATH_MAX], out[PATH_MAX];
    const BOOL compressed = !is_plain_image(disc);
    snprintf(source, sizeof source, "%s", disc);
    snprintf(plain, sizeof plain, "%s/GZLE01.iso", support);
    snprintf(out, sizeof out, "%s", game);
    g_prepare_from = compressed ? 0.8 : 0.0;
    atomic_store(&g_fraction, 0.0);
    atomic_store(&g_stage, compressed ? 0 : 1);
    atomic_store(&g_done, 0);
    g_result = 0;
    g_error[0] = '\0';

    [NSThread detachNewThreadWithBlock:^{
        if (compressed) {
            fprintf(stderr, "[app] unpacking %s to %s\n", source, plain);
            if (unpack_image(source, plain, g_error, sizeof g_error) != 0) {
                g_result = -1;
                atomic_store(&g_done, 1);
                return;
            }
        }
        atomic_store(&g_stage, 1);
        const char* image = compressed ? plain : source;
        fprintf(stderr, "[app] preparing %s\n", image);
        mkdir(out, 0755);
        g_result = bluewake_disc_prepare(image, out, prepare_progress, NULL, g_error, sizeof g_error);
        atomic_store(&g_done, 1);
    }];

    ensure_app();
    NSPanel* window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 112)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    window.title = kTitle;
    NSTextField* label = [NSTextField labelWithString:@""];
    label.frame = NSMakeRect(20, 64, 400, 20);
    NSProgressIndicator* bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 30, 400, 20)];
    bar.indeterminate = NO;
    bar.minValue = 0.0;
    bar.maxValue = 1.0;
    [window.contentView addSubview:label];
    [window.contentView addSubview:bar];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
    while (!atomic_load(&g_done)) {
        @autoreleasepool {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                                untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                                   inMode:NSDefaultRunLoopMode
                                                  dequeue:YES];
            if (event != nil)
                [NSApp sendEvent:event];
            label.stringValue = atomic_load(&g_stage) == 0 ? @"Unpacking your disc image (once)…"
                                                            : @"Preparing the game from your disc…";
            bar.doubleValue = atomic_load(&g_fraction);
        }
    }
    [window orderOut:nil];
    if (g_result == 0 && compressed)
        snprintf(disc, disc_size, "%s", plain);
    if (g_result != 0)
        fprintf(stderr, "[app] %s\n", g_error);
    return g_result;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        char exe[PATH_MAX], real[PATH_MAX];
        uint32_t exe_size = sizeof exe;
        if (_NSGetExecutablePath(exe, &exe_size) != 0 || realpath(exe, real) == NULL)
            return 1;
        // .../Wind Waker Recomp.app/Contents/MacOS/Wind Waker Recomp -> .../Contents
        char contents[PATH_MAX];
        snprintf(contents, sizeof contents, "%s", real);
        for (int i = 0; i < 2; ++i) {
            char* slash = strrchr(contents, '/');
            if (slash == NULL)
                return 1;
            *slash = '\0';
        }
        const char* home = getenv("HOME");
        if (home == NULL || home[0] == '\0')
            return 1;
        char support[PATH_MAX], logs[PATH_MAX], game[PATH_MAX], path[PATH_MAX];
        snprintf(support, sizeof support, "%s/Library/Application Support/Wind Waker Recomp", home);
        snprintf(logs, sizeof logs, "%s/logs", support);
        make_dirs(logs);
        snprintf(game, sizeof game, "%s/game", support);

        // One log per session.
        char stamp[32];
        const time_t now = time(NULL);
        strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", localtime(&now));
        snprintf(path, sizeof path, "%s/session-%s.log", logs, stamp);
        if (freopen(path, "w", stderr) != NULL)
            dup2(fileno(stderr), fileno(stdout));
        setvbuf(stderr, NULL, _IOLBF, 0);

        snprintf(path, sizeof path, "%s/settings.ini", support);
        if (!exists(path))
            write_text(path, kDefaultSettings);

        // The disc: the one chosen before while it is still there and prepared,
        // else a new choice, checked and prepared.
        char disc_file[PATH_MAX], disc[PATH_MAX], dol[PATH_MAX], rels[PATH_MAX];
        snprintf(disc_file, sizeof disc_file, "%s/disc.txt", support);
        snprintf(dol, sizeof dol, "%s/main.dol", game);
        snprintf(rels, sizeof rels, "%s/rels", game);
        const char* disc_env = getenv("BLUEWAKE_DISC");
        if (disc_env != NULL && disc_env[0] != '\0')
            snprintf(disc, sizeof disc, "%s", disc_env);
        else if (!read_line(disc_file, disc, sizeof disc))
            disc[0] = '\0';
        int ready = disc[0] != '\0' && exists(disc) && exists(dol) && exists(rels);
        if (!ready && disc[0] != '\0' && !exists(disc))
            show_alert(@"Your disc image has moved.",
                       @"The disc image chosen before is no longer where it was. Choose it again.", NO);
        // A disc that is there but not prepared yet (BLUEWAKE_DISC from a
        // terminal, or game/ removed) is prepared without asking; one that fails
        // is asked for.
        int ask = !(disc[0] != '\0' && exists(disc));
        while (!ready) {
            if (ask) {
                NSString* chosen = choose_disc();
                if (chosen == nil)
                    return 0;
                snprintf(disc, sizeof disc, "%s", chosen.fileSystemRepresentation);
            }
            ask = 1;
            if (prepare_disc(disc, sizeof disc, support, game) != 0) {
                show_alert(@"This disc image cannot be used.", [NSString stringWithUTF8String:g_error], YES);
                continue;
            }
            write_text(disc_file, disc);
            ready = 1;
        }

        char resources[PATH_MAX];
        snprintf(resources, sizeof resources, "%s/Resources", contents);
        setenv("BLUEWAKE_ROOT", resources, 0);
        setenv("BLUEWAKE_DISC", disc, 0);
        setenv("BLUEWAKE_DOL", dol, 0);
        setenv("BLUEWAKE_RELS_DIR", rels, 0);
        snprintf(path, sizeof path, "%s/GZLE01.card", support);
        setenv("BLUEWAKE_CARD_PATH", path, 0);
        snprintf(path, sizeof path, "%s/sram.bin", support);
        setenv("BLUEWAKE_SRAM", path, 0);
        snprintf(path, sizeof path, "%s/states", support); // F5 / F9 save states
        setenv("BLUEWAKE_STATE_DIR", path, 0);
        // The compiled shader and pipeline caches with the rest of the app's
        // data, not in a folder every copy of the host shares (two copies at
        // once wrote one SQLite file together, and the Dawn cache broke).
        setenv("DOL_AURORA_CACHE_DIR", support, 0);
        setenv("BLUEWAKE_CLOCK", "now", 0);
        setenv("BLUEWAKE_RENDERER", "aurora", 0);
        setenv("BLUEWAKE_DSP_MODE", "hle", 0);
        setenv("BLUEWAKE_WALL_PACE", "1", 0);
        setenv("BLUEWAKE_CYCLE_CAP", "16384", 0);
        setenv("BLUEWAKE_MAX_BLOCKS", "100000000000", 0);
        setenv("BLUEWAKE_PERF_LOG", "1", 0);
        if (chdir(support) != 0)
            fprintf(stderr, "[app] chdir %s: %s\n", support, strerror(errno));

        char host[PATH_MAX], module[PATH_MAX];
        snprintf(host, sizeof host, "%s/MacOS/bluewake_host", contents);
        snprintf(module, sizeof module, "%s/Frameworks/gGZLE01_recomp.dylib", contents);
        char* host_argv[] = {host, module, NULL};
        execv(host, host_argv);
        fprintf(stderr, "[app] could not run %s: %s\n", host, strerror(errno));
        show_alert(@"The game could not start.",
                   @"The session log is in ~/Library/Application Support/Wind Waker Recomp/logs.", YES);
        return 1;
    }
}
