// dmfix.m - puts the GL/Vulkan layer's frames on screen on devices without Metal 4.
//
// Dungeon1 1.3.0 decides at start-up that the Metal device has no MTLGPUFamilyMetal4
// (every A14/A15/A16 iPhone, the iPhone 12 Pro among them) and then takes the
// "classic part only" path: mtl_init() sets g_classic = 1, and mtl_present_ext()
// returns 0 on its first line. The game keeps running - audio plays, log.txt reports
// vkPresentKHR / glSwap - but nothing is ever drawn to the layer.
//
// This dylib hooks two local symbols of the main binary:
//   mtl_ext_tex(void *tex)       the layer registers its window textures here;
//                                serial -> MTLTexture is remembered
//   mtl_present_ext(serial, ..)  the layer offers a finished frame; it is drawn to
//                                the CAMetalLayer with the binary's own
//                                present_pipeline() / present_encode()
// The game, the shaders and the Metal 4 path on A17 Pro and newer are left alone:
// on such a device the Metal 4 path never goes through the hooked functions and
// nothing changes.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/vm_page_size.h>
#import <libkern/OSCacheControl.h>
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

// symtab_command.symoff/stroff are file offsets; __LINKEDIT is mapped with
// fileoff == vmaddr - slide - k, so the runtime address of file offset X is
// (le_vmaddr + slide - le_fileoff + X). Adding X to le_vmaddr alone reads
// le_fileoff bytes too far (27 MB here) and lands outside every region.
static void load_symbols(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    g_slide = _dyld_get_image_vmaddr_slide(0);
    if (!mh) return;
    uint64_t le_vmaddr = 0, le_fileoff = 0, le_size = 0;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, SEG_LINKEDIT) == 0) {
                le_vmaddr = sg->vmaddr; le_fileoff = sg->fileoff; le_size = sg->vmsize;
            }
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (!le_vmaddr || !le_size) return;
    uintptr_t base = (uintptr_t)(le_vmaddr + (uint64_t)g_slide - le_fileoff);
    g_le_start = (uintptr_t)(le_vmaddr + (uint64_t)g_slide);
    g_le_end = g_le_start + (uintptr_t)le_size;
    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SYMTAB) {
            const struct symtab_command *st = (const struct symtab_command *)lc;
            if (st->symoff >= le_size || st->stroff >= le_size) return;
            g_syms = (const struct nlist_64 *)(base + st->symoff);
            g_strtab = (const char *)(base + st->stroff);
            g_nsyms = st->nsyms;
            return;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
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

#pragma mark - arm64 hook

// movz x16,#lo / movk x16,#mid,lsl16 / movk x16,#hi,lsl32 / br x16
// Four words, no alignment or range requirement (the address fits in 48 bits).
static void write_abs_jump(uint32_t *at, uintptr_t dst) {
    at[0] = 0xd2800010u | (uint32_t)((dst & 0xffff) << 5);                 // movz x16
    at[1] = 0xf2a00010u | (uint32_t)(((dst >> 16) & 0xffff) << 5);         // movk x16, lsl 16
    at[2] = 0xf2c00010u | (uint32_t)(((dst >> 32) & 0xffff) << 5);         // movk x16, lsl 32
    at[3] = 0xd61f0200u;                                                   // br x16
}

static void *make_trampoline(void *target) {
    vm_address_t mem = 0;
    if (vm_allocate(mach_task_self(), &mem, (vm_size_t)vm_page_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return NULL;
    memcpy((void *)mem, target, 16);
    write_abs_jump((uint32_t *)(mem + 16), (uintptr_t)target + 16);
    if (vm_protect(mach_task_self(), mem, (vm_size_t)vm_page_size, FALSE,
                   VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), mem, (vm_size_t)vm_page_size);
        return NULL;
    }
    sys_icache_invalidate((void *)mem, (size_t)vm_page_size);
    return (void *)mem;
}

static int patch_entry(void *target, const uint32_t expect[4], void *replacement) {
    uint32_t *p = (uint32_t *)target;
    if (memcmp(p, expect, 16) != 0) return -1;
    uintptr_t page = (uintptr_t)target & ~((uintptr_t)vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, (vm_size_t)vm_page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { LOG(@"vm_protect rw failed: 0x%x", kr); return -1; }
    write_abs_jump(p, (uintptr_t)replacement);
    kr = vm_protect(mach_task_self(), page, (vm_size_t)vm_page_size, FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) LOG(@"vm_protect rx failed: 0x%x", kr);
    sys_icache_invalidate(target, 16);
    return 0;
}

#pragma mark - the game's own present code

typedef uint64_t (*ext_tex_fn)(void *tex);
typedef uint64_t (*present_ext_fn)(uint64_t serial, double period, void *ev, uint64_t ev_val, const int *crop);
typedef void *(*front_layer_fn)(void);
typedef void (*pipeline_fn)(uint32_t format);
typedef int (*encode_fn)(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int *crop);

static ext_tex_fn orig_ext_tex;
static front_layer_fn fn_front_layer;
static pipeline_fn fn_pipeline;
static encode_fn fn_encode;

#define MAPN 32
static uint64_t g_key[MAPN];
static __unsafe_unretained id<MTLTexture> g_val[MAPN];
static pthread_mutex_t g_map_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_val_next;

static void map_put(uint64_t k, id<MTLTexture> t) {
    pthread_mutex_lock(&g_map_mu);
    int slot = -1;
    for (int i = 0; i < MAPN && slot < 0; i++) if (g_key[i] == k) slot = i;
    for (int i = 0; i < MAPN && slot < 0; i++) if (!g_key[i]) slot = i;
    if (slot < 0) { slot = g_val_next; g_val_next = (g_val_next + 1) % MAPN; }
    g_key[slot] = k; g_val[slot] = t;
    pthread_mutex_unlock(&g_map_mu);
}

static id<MTLTexture> map_get(uint64_t k) {
    id<MTLTexture> r = nil;
    pthread_mutex_lock(&g_map_mu);
    for (int i = 0; i < MAPN; i++) if (g_key[i] == k) { r = g_val[i]; break; }
    pthread_mutex_unlock(&g_map_mu);
    return r;
}

static id<MTLCommandQueue> g_queue;
static int g_first = 1;

static uint64_t hook_ext_tex(void *tex) {
    uint64_t ser = orig_ext_tex(tex);
    map_put(ser, (__bridge id<MTLTexture>)tex);
    return ser;
}

static uint64_t hook_present_ext(uint64_t serial, double period, void *ev, uint64_t ev_val, const int *crop) {
    @autoreleasepool {
        id<MTLTexture> src = map_get(serial);
        if (!src) { LOG(@"present: serial %llu is not registered", (unsigned long long)serial); return 0; }
        void *lp = fn_front_layer ? fn_front_layer() : NULL;
        if (!lp) return 0;
        CAMetalLayer *layer = (__bridge CAMetalLayer *)lp;
        id<CAMetalDrawable> dr = [layer nextDrawable];
        if (!dr) return 0;
        if (!g_queue) g_queue = [layer.device newCommandQueue];
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        if (!cb) return 0;
        if (ev) [cb encodeWaitForEvent:(__bridge id<MTLSharedEvent>)ev value:ev_val];
        fn_pipeline((uint32_t)dr.texture.pixelFormat);
        if (!fn_encode(cb, src, dr.texture, crop)) {
            LOG(@"present: encode failed");
            [cb commit];
            return 0;
        }
        [cb presentDrawable:dr];
        [cb commit];
        if (g_first) {
            g_first = 0;
            LOG(@"present: first frame %lux%lu -> %lux%lu (layer %.0fx%.0f scale %.2f)",
                (unsigned long)src.width, (unsigned long)src.height,
                (unsigned long)dr.texture.width, (unsigned long)dr.texture.height,
                layer.bounds.size.width, layer.bounds.size.height, layer.contentsScale);
        }
    }
    return 0;
}

#pragma mark - entry

__attribute__((constructor)) static void dmfix_init(void) {
    @autoreleasepool {
        LOG(@"init");
        load_symbols();
        if (!g_syms) { LOG(@"no symbol table in the main binary"); return; }
        LOG(@"symtab %u entries, linkedit %p..%p", g_nsyms, (void *)g_le_start, (void *)g_le_end);

        fn_front_layer = (front_layer_fn)find_sym("_front_metal_layer");
        fn_pipeline = (pipeline_fn)find_sym("_present_pipeline");
        fn_encode = (encode_fn)find_sym("_present_encode");
        void *ext_tex = find_sym("_mtl_ext_tex");
        void *present_ext = find_sym("_mtl_present_ext");
        LOG(@"symbols: layer %p pipeline %p encode %p ext_tex %p present_ext %p",
            fn_front_layer, fn_pipeline, fn_encode, ext_tex, present_ext);
        if (!fn_front_layer || !fn_pipeline || !fn_encode || !ext_tex || !present_ext) return;

        // 1.3.0 prologues; another build is left untouched
        static const uint32_t ext_tex_pro[4] = { 0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0003f3 };
        static const uint32_t present_pro[4] = { 0xd10343ff, 0x6d0923e9, 0xa90a57f6, 0xa90b4ff4 };

        if (memcmp(ext_tex, ext_tex_pro, 16) != 0) { LOG(@"mtl_ext_tex: other prologue, skipped"); return; }
        void *t1 = make_trampoline(ext_tex);
        if (!t1) { LOG(@"mtl_ext_tex: no trampoline"); return; }
        orig_ext_tex = (ext_tex_fn)t1;
        if (patch_entry(ext_tex, ext_tex_pro, (void *)hook_ext_tex) != 0) { LOG(@"mtl_ext_tex: patch failed"); return; }

        if (memcmp(present_ext, present_pro, 16) != 0) { LOG(@"mtl_present_ext: other prologue, skipped"); return; }
        if (!make_trampoline(present_ext)) { LOG(@"mtl_present_ext: no trampoline"); return; }
        if (patch_entry(present_ext, present_pro, (void *)hook_present_ext) != 0) { LOG(@"mtl_present_ext: patch failed"); return; }

        LOG(@"hooks installed");
    }
}
