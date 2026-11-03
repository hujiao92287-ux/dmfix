// dmfix.m - puts the GL layer's frames on screen on devices without Metal 4.
//
// Dungeon1 1.3.0 decides at start-up that the Metal device has no MTLGPUFamilyMetal4
// (every A14/A15/A16 iPhone, the iPhone 12 Pro among them) and then takes the
// "classic part only" path: mtl_init() sets g_classic = 1 and nothing is presented.
// The game keeps running - the GL/Vulkan layer renders into its window textures,
// audio plays, saves work - but the present path is Metal 4 only
// (present_now -> present_encode_m4, MTL4CommandQueue), which does not exist on
// these GPUs, so every frame ends up nowhere.
//
// This dylib patches no code at all (an inline hook cannot restore PROT_EXEC on a
// page it has written to: the app is signed, so the kernel refuses, and the app
// dies the moment the patched function runs). It only reads the game's own state:
//
//   g_win            the GL layer's window struct: col[3] textures, cur ring index
//   front_metal_layer / present_pipeline / present_encode
//                    the program's own classic present code, which the screenshot
//                    path already uses and which runs fine on any Metal device
//
// A 120 Hz timer watches g_win->cur. Every time it advances the layer has finished
// a frame into col[old cur]; that texture is handed to the game's own
// present_pipeline()/present_encode() and shown on the CAMetalLayer's drawable,
// one swap later (so the GPU has certainly finished writing it).
//
// Nothing is written anywhere: a failure leaves the game exactly as it was, black
// screen and all, with the reason in Documents/dmfix.log.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <pthread.h>
#import <string.h>

#pragma mark - log

static void dm_log(NSString *s) {
    NSLog(@"[dmfix] %@", s);
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = dirs.count ? dirs.firstObject : NSTemporaryDirectory();
        FILE *f = fopen([dir stringByAppendingPathComponent:@"dmfix.log"].fileSystemRepresentation, "a");
        if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
    }
    pthread_mutex_unlock(&mu);
}
#define LOG(...) dm_log([NSString stringWithFormat:__VA_ARGS__])

#pragma mark - symbols of the main binary

static const char *g_strtab;
static const struct nlist_64 *g_syms;
static uint32_t g_nsyms;
static intptr_t g_slide;
static uintptr_t g_le_start, g_le_end;
static int g_image = -1;

static void *find_sym(const char *name);

// symtab_command.symoff/stroff are file offsets; __LINKEDIT is mapped with
// fileoff == vmaddr - slide - k, so the runtime address of file offset X is
// (le_vmaddr + slide - le_fileoff + X). They must also be bounds-checked against
// the segment's *file* range (fileoff .. fileoff + filesize), never its vm size.
static int load_symbols_for_image(uint32_t idx) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(idx);
    if (!mh || mh->magic != MH_MAGIC_64) return 0;
    intptr_t slide = _dyld_get_image_vmaddr_slide(idx);
    uint64_t le_vmaddr = 0, le_fileoff = 0, le_filesize = 0;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, SEG_LINKEDIT) == 0) {
                le_vmaddr = sg->vmaddr; le_fileoff = sg->fileoff; le_filesize = sg->filesize;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (!le_vmaddr || !le_filesize) return 0;
    uintptr_t base = (uintptr_t)(le_vmaddr + (uint64_t)slide - le_fileoff);
    uintptr_t le_start = (uintptr_t)(le_vmaddr + (uint64_t)slide);
    uint64_t le_file_end = le_fileoff + le_filesize;

    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) {
            const struct symtab_command *st = (const struct symtab_command *)lc;
            uint64_t sym_end = (uint64_t)st->symoff + (uint64_t)st->nsyms * sizeof(struct nlist_64);
            uint64_t str_end = (uint64_t)st->stroff + st->strsize;
            if ((uint64_t)st->symoff < le_fileoff || sym_end > le_file_end ||
                (uint64_t)st->stroff < le_fileoff || str_end > le_file_end)
                return 0;
            g_syms = (const struct nlist_64 *)(base + st->symoff);
            g_strtab = (const char *)(base + st->stroff);
            g_nsyms = st->nsyms;
            g_le_start = le_start;
            g_le_end = le_start + (uintptr_t)le_filesize;
            g_slide = slide;
            return 1;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

// The dylib is injected as LC_LOAD_DYLIB, so image 0 should be the game, but
// scan every image anyway and keep the one that actually exports the symbols.
static int load_symbols(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if (!load_symbols_for_image(i)) continue;
        if (find_sym("_g_win") && find_sym("_present_encode") &&
            find_sym("_present_pipeline") && find_sym("_front_metal_layer")) { g_image = (int)i; return 1; }
        g_syms = NULL; g_strtab = NULL; g_nsyms = 0;
    }
    return 0;
}

static void *find_sym(const char *name) {
    if (!g_syms || !g_strtab) return NULL;
    for (uint32_t i = 0; i < g_nsyms; i++) {
        uint32_t n = g_syms[i].n_un.n_strx;
        if (!n || (g_syms[i].n_type & N_STAB)) continue;
        if ((uintptr_t)(g_strtab + n) >= g_le_end) continue;
        if (strcmp(g_strtab + n, name) == 0 && g_syms[i].n_value)
            return (void *)(uintptr_t)(g_syms[i].n_value + (uint64_t)g_slide);
    }
    return NULL;
}

#pragma mark - the game's own present code

typedef void *(*front_layer_fn)(void);
typedef void (*pipeline_fn)(uint32_t format);
typedef int (*encode_fn)(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int *crop);

static front_layer_fn fn_front_layer;
static pipeline_fn fn_pipeline;
static encode_fn fn_encode;

// hle_gl.m: static struct { int made; uint32_t w, h; __strong id<MTLTexture> col[NWIN], ds;
//                           uint64_t serial[NWIN], ticket[NWIN]; int cur; } g_win;
// Offsets confirmed on 1.3.0 (win_make / eglSwapBuffers): col 0x10, ds 0x28,
// serial 0x30, ticket 0x48, cur 0x60.
#define NWIN 3
typedef struct {
    int made;
    uint32_t w, h;
    void *col[NWIN];
    void *ds;
    uint64_t serial[NWIN];
    uint64_t ticket[NWIN];
    int cur;
} dm_win;

static dm_win *g_win;

#pragma mark - presenter

static id<MTLCommandQueue> g_queue;
static dispatch_source_t g_timer;
static int g_last_cur = -1;
static id<MTLTexture> g_hold;
static unsigned long g_frames, g_ticks, g_miss_drawable, g_miss_layer, g_enc_fail;
static int g_first_logged;

static void present_one(id<MTLTexture> src) {
    if (!src) return;
    void *lp = fn_front_layer();
    if (!lp) { if (g_miss_layer++ < 3) LOG(@"present: front_metal_layer returned NULL"); return; }
    CAMetalLayer *layer = (__bridge CAMetalLayer *)lp;
    if (![layer isKindOfClass:[CAMetalLayer class]]) { if (g_miss_layer++ < 3) LOG(@"present: front layer is a %s", class_getName(object_getClass(layer))); return; }
    layer.allowsNextDrawableTimeout = YES;   // never block the driver queue when a drawable is not ready

    // The layer is sized by the app when it is laid out; on the classic path that may
    // never have happened, so give it the game's own window size once.
    if (g_win->w && g_win->h && (layer.drawableSize.width < 1 || layer.drawableSize.height < 1)) {
        CGFloat sc = layer.contentsScale > 0 ? layer.contentsScale : 1;
        layer.drawableSize = CGSizeMake(g_win->w * sc, g_win->h * sc);
        LOG(@"present: layer had no drawable size, set to %.0fx%.0f", layer.drawableSize.width, layer.drawableSize.height);
    }

    id<CAMetalDrawable> dr = [layer nextDrawable];
    if (!dr) {
        if (g_miss_drawable++ < 3 || (g_miss_drawable % 300) == 0)
            LOG(@"present: nextDrawable nil (%lu times, layer %.0fx%.0f drawable %.0fx%.0f scale %.2f superlayer %d)",
                g_miss_drawable, layer.bounds.size.width, layer.bounds.size.height,
                layer.drawableSize.width, layer.drawableSize.height, layer.contentsScale,
                layer.superlayer != nil);
        return;
    }
    if (!g_queue) g_queue = [layer.device newCommandQueue];
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    if (!cb) { if (g_miss_layer++ < 3) LOG(@"present: no command buffer"); return; }

    fn_pipeline((uint32_t)dr.texture.pixelFormat);
    if (!fn_encode(cb, src, dr.texture, NULL)) {
        if (g_enc_fail++ < 3) LOG(@"present: present_encode refused %lux%lu fmt %lu -> %lux%lu fmt %lu",
                                   (unsigned long)src.width, (unsigned long)src.height, (unsigned long)src.pixelFormat,
                                   (unsigned long)dr.texture.width, (unsigned long)dr.texture.height,
                                   (unsigned long)dr.texture.pixelFormat);
        [cb commit];
        return;
    }
    [cb presentDrawable:dr];
    [cb commit];
    g_frames++;

    if (!g_first_logged) {
        g_first_logged = 1;
        LOG(@"present: first frame %lux%lu fmt %lu -> %lux%lu fmt %lu (layer %.0fx%.0f drawable %.0fx%.0f scale %.2f superlayer %d)",
            (unsigned long)src.width, (unsigned long)src.height, (unsigned long)src.pixelFormat,
            (unsigned long)dr.texture.width, (unsigned long)dr.texture.height, (unsigned long)dr.texture.pixelFormat,
            layer.bounds.size.width, layer.bounds.size.height,
            layer.drawableSize.width, layer.drawableSize.height, layer.contentsScale,
            layer.superlayer != nil);
    } else if ((g_frames % 300) == 0) {
        LOG(@"present: %lu frames (%lu ticks)", g_frames, g_ticks);
    }
}

// 120 Hz: g_win->cur advances once per eglSwapBuffers, i.e. once per game frame.
static void dmfix_tick(void) {
    @autoreleasepool {
        g_ticks++;
        dm_win *w = g_win;
        if (!w) return;
        if (!w->made) {
            g_last_cur = -1; g_hold = nil;
            if ((g_ticks % 600) == 0) LOG(@"waiting: window not made yet");
            return;
        }
        int cur = w->cur;
        if (cur < 0 || cur >= NWIN) return;
        if (cur != g_last_cur) {
            int prev = g_last_cur;
            g_last_cur = cur;
            if (prev < 0) return;   // first sighting: nothing has been drawn into any buffer yet
            id<MTLTexture> done = (__bridge id<MTLTexture>)w->col[prev];
            if (g_hold) present_one(g_hold);   // one swap late: the GPU has surely finished writing it
            g_hold = done;
        }
    }
}

#pragma mark - entry

__attribute__((constructor)) static void dmfix_init(void) {
    @autoreleasepool {
        LOG(@"init (v3: no code patching, present side driver)");
        if (!load_symbols()) { LOG(@"no symbol table with the game's symbols (%u images scanned)", _dyld_image_count()); return; }
        LOG(@"symtab: image %d (%s), %u entries", g_image, _dyld_get_image_name((uint32_t)g_image), g_nsyms);

        fn_front_layer = (front_layer_fn)find_sym("_front_metal_layer");
        fn_pipeline = (pipeline_fn)find_sym("_present_pipeline");
        fn_encode = (encode_fn)find_sym("_present_encode");
        g_win = (dm_win *)find_sym("_g_win");
        LOG(@"symbols: layer %p pipeline %p encode %p g_win %p",
            fn_front_layer, fn_pipeline, fn_encode, g_win);
        if (!fn_front_layer || !fn_pipeline || !fn_encode || !g_win) return;

        dispatch_queue_t q = dispatch_queue_create("dmfix.present", DISPATCH_QUEUE_SERIAL);
        g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        if (!g_timer) { LOG(@"no timer"); return; }
        dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  8ull * NSEC_PER_MSEC, 1ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_timer, ^{ dmfix_tick(); });
        dispatch_resume(g_timer);
        LOG(@"present driver running");
    }
}
