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

// --- C ABI owned by nview.nim (gallery model + decoders) ---
extern int galleryCount(void);
extern int galleryIndex(void);
extern int galleryGo(int delta);
extern const char *galleryCurrentName(void);
extern unsigned char *galleryCurrentPixels(int *w, int *h);

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
  id<MTLTexture> texture; // retained; replaced per image
  int imgW;
  int imgH;
}
- (void)goDelta:(int)d;
- (void)render;
@end

@implementation GalleryController

- (instancetype)init {
  if ((self = [super init])) {
    texture = nil;
    imgW = 0;
    imgH = 0;
  }
  return self;
}

- (void)dealloc {
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
  [device retain];
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
  [pipeline retain];
  return YES;
}

// ----- image loading -----

- (void)uploadCurrentTexture {
  int w = 0, h = 0;
  unsigned char *px = galleryCurrentPixels(&w, &h);
  if (!px || w <= 0 || h <= 0) return;
  MTLTextureDescriptor *desc =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                    MTLPixelFormatRGBA8Unorm
                                                         width:w
                                                        height:h
                                                     mipmapped:NO];
  id<MTLTexture> t = [device newTextureWithDescriptor:desc];
  [t replaceRegion:MTLRegionMake2D(0, 0, w, h)
       mipmapLevel:0
         withBytes:px
       bytesPerRow:w * 4];
  [texture release];
  texture = [t retain];
  [t release];
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
  int idx = galleryGo(d);
  if (idx < 0) {
    NSBeep(); // target failed to decode; Nim logged why. Keep old image.
    return;
  }
  (void)idx;
  [self uploadCurrentTexture];
  [self updateTitle];
  [self render];
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
  // Row 0 (image top) is texel v=0; clip y is up.
  const float verts[4][4] = {
      {-fx, -fy, 0.0f, 1.0f},
      {fx, -fy, 1.0f, 1.0f},
      {-fx, fy, 0.0f, 0.0f},
      {fx, fy, 1.0f, 0.0f},
  };
  id<MTLBuffer> vb = [device newBufferWithBytes:verts
                                         length:sizeof(verts)
                                        options:MTLResourceStorageModeShared];
  MTLRenderPassDescriptor *rp =
      [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = drawable.texture;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.08, 1.0);
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:pipeline];
  [enc setVertexBuffer:vb offset:0 atIndex:0];
  [enc setFragmentTexture:texture atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
  [enc endEncoding];
  [cb presentDrawable:drawable];
  [cb commit];
  [vb release];
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
    nameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 22)];
    nameField.bezeled = NO;
    nameField.drawsBackground = NO;
    nameField.editable = NO;
    nameField.selectable = NO;
    nameField.alignment = NSTextAlignmentCenter;
    nameField.font = [NSFont systemFontOfSize:13];
    NSToolbarItem *it =
        [[[NSToolbarItem alloc] initWithItemIdentifier:ident] autorelease];
    it.label = @"Picture";
    it.paletteLabel = @"Picture name";
    it.view = nameField;
    it.minSize = NSMakeSize(200, 22);
    it.maxSize = NSMakeSize(600, 22);
    return it;
  }
  return nil;
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
  [self updateTitle];
  [self render];
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
