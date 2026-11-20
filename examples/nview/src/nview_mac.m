// nview_mac.m — native macOS UI + Metal renderer for the nview gallery.
//
// Manual reference counting throughout (no ARC flag surgery in the Nim
// build): app-lifetime objects are released where the App retains them,
// the per-image texture is explicitly retained/released on navigation.
//
// Layout: NSApplication → GalleryController (app + toolbar delegate)
//   → NSWindow (toolbar: [prev] <name> [next])
//   → MetalImageView (CAMetalLayer-backed) → Metal textured quad.

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach.h>

static double nviewFootprintMB(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) !=
      KERN_SUCCESS)
    return -1;
  return (double)info.phys_footprint / 1048576.0;
}

// --- C ABI owned by nview.nim (gallery model + decoders) ---
extern int galleryCount(void);
extern int galleryIndex(void);
extern int galleryGo(int delta);
extern const char *galleryCurrentName(void);
extern unsigned char *galleryCurrentPixels(int *w, int *h);
extern void galleryDropPixels(void);

static NSString *const kPrevItem = @"nview.prev";
static NSString *const kNameItem = @"nview.name";
static NSString *const kNextItem = @"nview.next";

static const char *kShaders =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vin { float2 pos; float2 uv; };\n"
    "struct Vout { float4 p [[position]]; float2 uv; };\n"
    "vertex Vout vsmain(const device Vin *v [[buffer(0)]],\n"
    "                   uint id [[vertex_id]]) {\n"
    "  Vout o; o.p = float4(v[id].pos, 0.0, 1.0); o.uv = v[id].uv;\n"
    "  return o;\n"
    "}\n"
    "fragment float4 fsmain(Vout in [[stage_in]],\n"
    "                       texture2d<float> tex [[texture(0)]]) {\n"
    "  constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "  return tex.sample(s, in.uv);\n"
    "}\n";

@class GalleryController;

// --- Metal-backed view: aspect-fit redraw on resize ---

@interface MetalImageView : NSView {
@public
  __unsafe_unretained id controller; // GalleryController, assign (no cycle)
}
@end

@implementation MetalImageView

+ (Class)layerClass {
  return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(NSRect)frame controller:(id)c {
  if ((self = [super initWithFrame:frame])) {
    controller = c;
    // Explicit layer (rather than relying on +layerClass): deterministic
    // across AppKit versions. Layer-hosting views don't auto-resize
    // their layer, so setFrameSize: keeps it in sync below.
    CAMetalLayer *layer = [CAMetalLayer layer];
    self.layer = layer;
    self.wantsLayer = YES;
  }
  return self;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  self.layer.frame = NSMakeRect(0, 0, size.width, size.height);
  [controller render];
}

- (void)viewDidChangeBackingProperties {
  [super viewDidChangeBackingProperties];
  [controller render];
}

- (void)keyDown:(NSEvent *)event {
  // Left/Right navigate, Esc/Q quit. (Buttons call the same paths.)
  switch (event.keyCode) {
    case 123: [controller goDelta:-1]; return;
    case 124: [controller goDelta:1]; return;
    case 53: [NSApp terminate:nil]; return;
    default: break;
  }
  if ([[event charactersIgnoringModifiers] isEqualToString:@"q"]) {
    [NSApp terminate:nil];
    return;
  }
  [super keyDown:event];
}

@end

// --- Controller: window, toolbar, Metal state, navigation ---

@interface GalleryController : NSObject <NSToolbarDelegate,
                                        NSApplicationDelegate> {
@public
  NSWindow *window;
  MetalImageView *view;
  NSTextField *nameField;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  id<MTLRenderPipelineState> pipeline;
  id<MTLTexture> texture; // retained; grow-only, reused across images
  id<MTLCommandBuffer> lastCmd; // retained; guards texture reuse hazards
  int imgW;
  int imgH;
  int texW; // allocated texture dimensions (>= imgW/imgH)
  int texH;
}
- (void)goDelta:(int)d;
- (void)render;
- (void)autoAdvance:(NSTimer *)timer;
@end

@implementation GalleryController

- (instancetype)init {
  if ((self = [super init])) {
    texture = nil;
    lastCmd = nil;
    imgW = 0;
    imgH = 0;
    texW = 0;
    texH = 0;
  }
  return self;
}

- (void)dealloc {
  [lastCmd release];
  [texture release];
  [pipeline release];
  [queue release];
  [device release];
  [nameField release];
  // window/view released by the App on terminate.
  [super dealloc];
}

// ----- Metal setup -----

- (BOOL)setupMetal:(NSError **)err {
  device = MTLCreateSystemDefaultDevice();
  if (!device) {
    if (err) {
      *err = [NSError errorWithDomain:@"nview" code:1 userInfo:@{
        NSLocalizedDescriptionKey : @"no Metal device"
      }];
    }
    return NO;
  }
  // MTLCreateSystemDefaultDevice follows the Create rule (caller owns,
  // +1); dealloc releases once, so no extra retain here.
  queue = [device newCommandQueue];
  NSString *src = [NSString stringWithUTF8String:kShaders];
  id<MTLLibrary> lib = [device newLibraryWithSource:src
                                            options:nil
                                              error:err];
  if (!lib) return NO;
  id<MTLFunction> vs = [lib newFunctionWithName:@"vsmain"];
  id<MTLFunction> fs = [lib newFunctionWithName:@"fsmain"];
  [lib release];
  if (!vs || !fs) return NO;
  MTLRenderPipelineDescriptor *pd =
      [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
  pd.vertexFunction = vs;
  pd.fragmentFunction = fs;
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  pipeline = [device newRenderPipelineStateWithDescriptor:pd error:err];
  [vs release];
  [fs release];
  if (!pipeline) return NO;
  // new* already transfers ownership (+1), matching the single release
  // in dealloc — no extra retain.
  return YES;
}

// ----- image loading -----

- (void)uploadCurrentTexture {
  int w = 0, h = 0;
  unsigned char *px = galleryCurrentPixels(&w, &h);
  if (!px || w <= 0 || h <= 0) return;
  // Grow-only texture: slides of different sizes reuse the same GPU
  // allocation instead of allocating/releasing one texture per photo.
  // A new allocation happens only when a photo exceeds the current
  // capacity, so a gallery settles at its largest slide.
  // Reusing the texture means overwriting pixels the previous frame may
  // still be sampling. Wait for that command buffer before writing (it
  // is normally already done; decode happened first). Fresh allocations
  // don't need this because the old texture is never overwritten.
  if (texture && w <= texW && h <= texH && lastCmd) {
    [lastCmd waitUntilCompleted];
    [lastCmd release];
    lastCmd = nil;
  }
  if (!texture || w > texW || h > texH) {
    int nw = w > texW ? w : texW;
    int nh = h > texH ? h : texH;
    // Guard against pathological mixes (e.g. 6000x100 then 100x6000):
    // if max-of-each would waste more than 2x the useful area, take the
    // exact new dimensions instead.
    long long grown = (long long)nw * nh;
    long long need = (long long)w * h;
    long long oldArea = (long long)texW * texH;
    long long cap = 2 * (need > oldArea ? need : oldArea);
    if (grown > cap) {
      nw = w;
      nh = h;
    }
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                      MTLPixelFormatRGBA8Unorm
                                                           width:nw
                                                          height:nh
                                                       mipmapped:NO];
    id<MTLTexture> t = [device newTextureWithDescriptor:desc];
    if (!t) return;
    [texture release];
    texture = t; // new* transfers ownership (+1); dealloc releases once.
    texW = nw;
    texH = nh;
  }
  [texture replaceRegion:MTLRegionMake2D(0, 0, w, h)
             mipmapLevel:0
               withBytes:px
             bytesPerRow:w * 4];
  imgW = w;
  imgH = h;
}

- (void)updateTitle {
  // Single title: the centered toolbar name. The window title bar stays
  // empty (traffic lights only) so the name appears exactly once.
  const char *name = galleryCurrentName();
  NSString *s = name ? [NSString stringWithUTF8String:name] : @"nview";
  if (!s) s = @"nview";
  nameField.stringValue = s;
}

- (void)goDelta:(int)d {
  // Own pool per navigation: decode, texture upload and render create
  // Foundation/Metal temporaries; draining at slide boundaries keeps
  // steady-state memory deterministic regardless of caller (button,
  // key, or timer).
  @autoreleasepool {
    int idx = galleryGo(d);
    if (idx < 0) {
      NSBeep(); // target failed to decode; Nim logged why. Keep old image.
      return;
    }
    (void)idx;
    [self uploadCurrentTexture];
    // The texture now owns the on-screen image; drop Nim's CPU copy so
    // steady state is scratch capacities, not one pinned full image.
    // Safe: nothing reads galleryCurrentPixels until the next loadAt,
    // which replaces the cache wholesale (resize renders from texture).
    galleryDropPixels();
    [self updateTitle];
    [self render];
    if (getenv("NVIEW_LOG_MEM")) {
      NSLog(@"nview-mem idx=%d %dx%d tex=%dx%d footprint=%.2fMB", idx, imgW,
            imgH, texW, texH, nviewFootprintMB());
    }
  }
}

// Test hook: drive the exact button path on a timer so memory can be
// sampled in-process (no debugger JIT contamination). Off unless
// NVIEW_AUTO_MS is set.
- (void)autoAdvance:(NSTimer *)timer {
  (void)timer;
  [self goDelta:1];
}

// ----- rendering -----

- (void)render {
  if (!texture || !window || !view) return;
  CAMetalLayer *layer = (CAMetalLayer *)view.layer;
  if (![layer isKindOfClass:[CAMetalLayer class]]) return;
  layer.device = device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.framebufferOnly = YES;
  CGFloat scale = window.backingScaleFactor;
  if (scale <= 0) scale = 1;
  NSSize bs = view.bounds.size;
  if (bs.width < 1 || bs.height < 1) return;
  layer.drawableSize = CGSizeMake(bs.width * scale, bs.height * scale);
  id<CAMetalDrawable> drawable = [layer nextDrawable];
  if (!drawable) return;

  // Aspect-fit: clip-space half-extents of the image rect.
  float dw = (float)layer.drawableSize.width;
  float dh = (float)layer.drawableSize.height;
  float s = fminf(dw / (float)imgW, dh / (float)imgH);
  float fx = (imgW * s) / dw;
  float fy = (imgH * s) / dh;
  // Row 0 (image top) is texel v=0; clip y is up. UVs map the used
  // texel region (the texture can be larger than the current photo);
  // half-texel insets keep linear filtering from bleeding into the
  // unused area. Exact-size textures are still sampled correctly
  // (texel centers).
  float u0 = 0.5f / (float)texW;
  float v0 = 0.5f / (float)texH;
  float u1 = ((float)imgW - 0.5f) / (float)texW;
  float v1 = ((float)imgH - 0.5f) / (float)texH;
  const float verts[4][4] = {
      {-fx, -fy, u0, v1},
      {fx, -fy, u1, v1},
      {-fx, fy, u0, v0},
      {fx, fy, u1, v0},
  };
  MTLRenderPassDescriptor *rp =
      [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = drawable.texture;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.08, 1.0);
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:pipeline];
  [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
  [enc setFragmentTexture:texture atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
  [enc endEncoding];
  [cb presentDrawable:drawable];
  [cb commit];
  [lastCmd release];
  lastCmd = [cb retain];
}

// ----- toolbar -----

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
        itemForItemIdentifier:(NSString *)ident
    willBeInsertedIntoToolbar:(BOOL)flag {
  (void)toolbar;
  (void)flag;
  if ([ident isEqualToString:kPrevItem]) {
    NSButton *b = [NSButton buttonWithTitle:@"‹ Prev"
                                     target:self
                                     action:@selector(goPrev:)];
    b.bezelStyle = NSTexturedRoundedBezelStyle;
    NSToolbarItem *it =
        [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
    it.label = @"Previous";
    it.paletteLabel = @"Previous picture";
    it.view = b;
    return it;
  }
  if ([ident isEqualToString:kNextItem]) {
    NSButton *b = [NSButton buttonWithTitle:@"Next ›"
                                     target:self
                                     action:@selector(goNext:)];
    b.bezelStyle = NSTexturedRoundedBezelStyle;
    NSToolbarItem *it =
        [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
    it.label = @"Next";
    it.paletteLabel = @"Next picture";
    it.view = b;
    return it;
  }
  if ([ident isEqualToString:kNameItem]) {
    // The field is created once and owned by the controller. Toolbar
    // rebuilds (and customization-palette previews, which must never
    // clobber — let alone dangle — the live ivar) get a throwaway copy.
    NSTextField *field = nil;
    if (flag) {
      if (!nameField) {
        nameField = [[self makeNameField] retain];
      } else {
        // Moving to a fresh item: detach from the discarded one first
        // (a view can only live in one superview).
        [nameField removeFromSuperview];
      }
      field = nameField;
    } else {
      field = [self makeNameField];
    }
    NSToolbarItem *it =
        [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
    it.label = @"Picture";
    it.paletteLabel = @"Picture name";
    it.view = field;
    it.minSize = NSMakeSize(200, 22);
    it.maxSize = NSMakeSize(600, 22);
    return it;
  }
  return nil;
}

// ----- shared name-field factory (autoreleased) -----

- (NSTextField *)makeNameField {
  NSTextField *f =
      [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 22)]
          autorelease];
  f.bezeled = NO;
  f.drawsBackground = NO;
  f.editable = NO;
  f.selectable = NO;
  f.alignment = NSTextAlignmentCenter;
  f.font = [NSFont systemFontOfSize:13];
  return f;
}

- (NSArray<NSString *> *)toolbarAllowedItemIdentifiers:(NSToolbar *)t {
  (void)t;
  return @[
    kPrevItem, kNameItem, kNextItem,
    NSToolbarFlexibleSpaceItemIdentifier,
    NSToolbarSpaceItemIdentifier,
  ];
}

- (NSArray<NSString *> *)toolbarDefaultItemIdentifiers:(NSToolbar *)t {
  (void)t;
  // Prev pinned left, name truly centered, Next pinned right. The
  // flexible spaces absorb the width difference between the two buttons
  // so the picture name stays centered instead of drifting.
  return @[
    kPrevItem,
    NSToolbarFlexibleSpaceItemIdentifier,
    kNameItem,
    NSToolbarFlexibleSpaceItemIdentifier,
    kNextItem,
  ];
}

- (void)goPrev:(id)sender {
  (void)sender;
  [self goDelta:-1];
}

- (void)goNext:(id)sender {
  (void)sender;
  [self goDelta:1];
}

// ----- app -----

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  (void)note;
  NSError *err = nil;
  if (![self setupMetal:&err]) {
    NSLog(@"nview: Metal unavailable: %@", err);
    [NSApp terminate:nil];
    return;
  }
  int w = 0, h = 0;
  if (!galleryCurrentPixels(&w, &h) || w <= 0 || h <= 0) {
    NSLog(@"nview: no image loaded");
    [NSApp terminate:nil];
    return;
  }
  // Window sized to the first image, clamped like the old viewer.
  double iw = w, ih = h;
  double f = fmin(1.0, fmin(1280.0 / iw, 800.0 / ih));
  NSRect frame = NSMakeRect(0, 0, iw * f, ih * f);
  window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable |
                           NSWindowStyleMaskResizable)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.title = @""; // title lives in the toolbar, not the title bar
  [window center];
  NSToolbar *tb = [[[NSToolbar alloc] initWithIdentifier:@"nview"] autorelease];
  tb.delegate = self;
  // IconOnly: the Prev/Next buttons and the name field are custom views
  // (their own titles/text stay visible); the small toolbar labels below
  // ("Previous"/"Picture"/"Next") would only add noise, so hide them.
  tb.displayMode = NSToolbarDisplayModeIconOnly;
  window.toolbar = tb;
  view = [[[MetalImageView alloc] initWithFrame:frame
                                     controller:self] autorelease];
  window.contentView = view;
  [window makeFirstResponder:view];
  [window makeKeyAndOrderFront:nil];
  [self uploadCurrentTexture];
  galleryDropPixels(); // steady state from here: see goDelta:
  [self updateTitle];
  [self render];
  const char *autoMs = getenv("NVIEW_AUTO_MS");
  if (autoMs && atoi(autoMs) > 0) {
    [NSTimer scheduledTimerWithTimeInterval:(double)atoi(autoMs) / 1000.0
                                     target:self
                                   selector:@selector(autoAdvance:)
                                   userInfo:nil
                                    repeats:YES];
  }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  (void)app;
  return YES;
}

@end

static void buildMenu(void) {
  NSMenu *mainMenu = [[NSMenu alloc] init];
  NSMenuItem *appItem = [[NSMenuItem alloc] init];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"nview"];
  [appMenu addItemWithTitle:@"Quit nview"
                     action:@selector(terminate:)
              keyEquivalent:@"q"];
  [appItem setSubmenu:appMenu];
  [mainMenu addItem:appItem];
  [NSApp setMainMenu:mainMenu];
  [mainMenu release];
  [appItem release];
  [appMenu release];
}

void nview_run(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    GalleryController *ctl = [[GalleryController alloc] init];
    [NSApp setDelegate:ctl];
    buildMenu();
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp run];
    [ctl release];
  }
}
