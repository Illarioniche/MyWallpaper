#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenSaver/ScreenSaver.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>

// All C symbols and storage are private to this Mach-O image. There are no
// statically registered custom classes: different exported bundles can coexist
// in the same legacy screen-saver host, each with its own principal class.
static NSURL *MWBundleURL;
static char MWStateKey;

static NSMutableDictionary *MWState(__unsafe_unretained id view) {
    return objc_getAssociatedObject(view, &MWStateKey);
}

static void MWCallSuper(__unsafe_unretained id view, SEL selector) {
    IMP implementation = class_getMethodImplementation(ScreenSaverView.class, selector);
    ((void (*)(__unsafe_unretained id, SEL))implementation)(view, selector);
}

static void MWReleasePlayback(NSMutableDictionary *state) {
    AVURLAsset *asset = state[@"asset"];
    [asset cancelLoading];
    AVQueuePlayer *player = state[@"player"];
    AVPlayerLooper *looper = state[@"looper"];
    [player pause];
    [looper disableLooping];
    [player removeAllItems];
    AVPlayerLayer *videoLayer = state[@"videoLayer"];
    videoLayer.player = nil;
    [state removeObjectsForKeys:@[@"asset", @"player", @"looper", @"appliedPlayback"]];
    CALayer *posterLayer = state[@"posterLayer"];
    posterLayer.hidden = NO;
}

static void MWShowFailure(ScreenSaverView *view, BOOL invalidVideo) {
    NSMutableDictionary *state = MWState(view);
    state[@"failed"] = @YES;
    MWReleasePlayback(state);
    CALayer *posterLayer = state[@"posterLayer"];
    posterLayer.contents = nil;
    BOOL russian = [NSLocale.preferredLanguages.firstObject.lowercaseString hasPrefix:@"ru"];
    NSString *message;
    if (invalidVideo) {
        message = russian
            ? @"MyWallpaper\nНе удалось воспроизвести видео. Выберите другое видео и создайте заставку заново."
            : @"MyWallpaper\nThis video could not be played. Choose another video and create the screen saver again.";
    } else {
        message = russian
            ? @"MyWallpaper\nНе удалось прочитать заставку. Создайте её заново в приложении."
            : @"MyWallpaper\nThis screen saver could not be read. Create it again in the app.";
    }
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    CATextLayer *messageLayer = state[@"messageLayer"];
    messageLayer.string = [[NSAttributedString alloc] initWithString:message attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:view.isPreview ? 12 : 22],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSParagraphStyleAttributeName: paragraph
    }];
    messageLayer.hidden = NO;
}

static NSURL *MWResource(NSString *filename) {
    NSURL *url = [[MWBundleURL URLByAppendingPathComponent:@"Contents/Resources" isDirectory:YES]
                  URLByAppendingPathComponent:filename];
    NSDictionary *values = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] error:nil];
    NSString *root = [MWBundleURL.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    if (![values[NSURLIsRegularFileKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]
        || ![url.URLByResolvingSymlinksInPath.path hasPrefix:root]) return nil;
    return url;
}

static BOOL MWReadBoolean(NSDictionary *json, NSString *key, BOOL fallback, BOOL *valid) {
    id value = json[key];
    if (!value || value == NSNull.null) return fallback;
    if (![value isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        *valid = NO;
        return fallback;
    }
    return [value boolValue];
}

static void MWReadConfiguration(ScreenSaverView *view) {
    NSMutableDictionary *state = MWState(view);
    state[@"failed"] = @NO;
    [state removeObjectsForKeys:@[@"configuration", @"videoURL"]];
    CATextLayer *messageLayer = state[@"messageLayer"];
    messageLayer.hidden = YES;
    CALayer *posterLayer = state[@"posterLayer"];
    posterLayer.contents = nil;
    posterLayer.hidden = NO;

    NSURL *configURL = MWResource(@"configuration.json");
    NSNumber *size = [configURL resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey];
    if (!configURL || size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > 65536) {
        MWShowFailure(view, NO);
        return;
    }
    NSData *data = [NSData dataWithContentsOfURL:configURL options:0 error:nil];
    id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![decoded isKindOfClass:NSDictionary.class]) { MWShowFailure(view, NO); return; }
    NSDictionary *json = decoded;
    id version = json[@"version"];
    if (version && version != NSNull.null && (![version isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() || [version doubleValue] != 1)) {
        MWShowFailure(view, NO);
        return;
    }
    NSString *filename = json[@"videoFileName"];
    id scaling = json[@"scaling"];
    if (!scaling || scaling == NSNull.null) scaling = @"fill";
    if (![filename isKindOfClass:NSString.class] || ![@[@"video.mp4", @"video.mov"] containsObject:filename]
        || ![scaling isKindOfClass:NSString.class] || ![@[@"fill", @"fit"] containsObject:scaling]) {
        MWShowFailure(view, NO);
        return;
    }
    BOOL valid = YES;
    BOOL battery = MWReadBoolean(json, @"animateOnBattery", NO, &valid);
    BOOL external = MWReadBoolean(json, @"animateOnExternalPower", YES, &valid);
    BOOL lowPower = MWReadBoolean(json, @"pauseInLowPowerMode", YES, &valid);
    NSURL *videoURL = MWResource(filename);
    NSURL *posterURL = MWResource(@"poster.jpg");
    if (!valid || !videoURL || !posterURL) { MWShowFailure(view, NO); return; }
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:posterURL];
    CGImageRef poster = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!poster) { MWShowFailure(view, NO); return; }
    state[@"configuration"] = @{@"animateOnBattery": @(battery), @"animateOnExternalPower": @(external),
                                @"pauseInLowPowerMode": @(lowPower)};
    state[@"videoURL"] = videoURL;
    AVPlayerLayer *videoLayer = state[@"videoLayer"];
    BOOL fit = [scaling isEqualToString:@"fit"];
    videoLayer.videoGravity = fit ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResizeAspectFill;
    posterLayer.contentsGravity = fit ? kCAGravityResizeAspect : kCAGravityResizeAspectFill;
    posterLayer.contents = (__bridge id)poster;
}

static void MWUpdatePlayback(ScreenSaverView *view) {
    NSMutableDictionary *state = MWState(view);
    if (![state[@"active"] boolValue] || [state[@"failed"] boolValue]) return;
    AVQueuePlayer *player = state[@"player"];
    if (!player) return;
    AVPlayerLooper *looper = state[@"looper"];
    if (player.status == AVPlayerStatusFailed || looper.status == AVPlayerLooperStatusFailed
        || player.currentItem.status == AVPlayerItemStatusFailed) {
        MWShowFailure(view, YES);
        return;
    }
    BOOL battery = NO;
    CFTypeRef snapshot = IOPSCopyPowerSourcesInfo();
    if (snapshot) {
        CFStringRef source = IOPSGetProvidingPowerSourceType(snapshot);
        if (source) battery = CFEqual(source, CFSTR(kIOPMBatteryPowerKey)) || CFEqual(source, CFSTR(kIOPMUPSPowerKey));
        CFRelease(snapshot);
    }
    NSDictionary *config = state[@"configuration"];
    BOOL shouldPlay = [config[battery ? @"animateOnBattery" : @"animateOnExternalPower"] boolValue]
        && !([config[@"pauseInLowPowerMode"] boolValue] && NSProcessInfo.processInfo.lowPowerModeEnabled);
    NSNumber *applied = state[@"appliedPlayback"];
    if (!applied || applied.boolValue != shouldPlay) {
        state[@"appliedPlayback"] = @(shouldPlay);
        if (shouldPlay) [player play]; else [player pause];
    }
    AVPlayerLayer *videoLayer = state[@"videoLayer"];
    CALayer *posterLayer = state[@"posterLayer"];
    // Keep the exported poster for cold static starts and until AVPlayer has
    // a real frame. Checking once per second avoids a per-frame drawing timer.
    posterLayer.hidden = shouldPlay && videoLayer.readyForDisplay;
}

static void MWInstallPlayer(ScreenSaverView *view, AVURLAsset *asset) {
    NSMutableDictionary *state = MWState(view);
    AVQueuePlayer *player = [[AVQueuePlayer alloc] init];
    player.muted = YES;
    player.volume = 0;
    player.preventsDisplaySleepDuringVideoPlayback = NO;
    AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:[AVPlayerItem playerItemWithAsset:asset]];
    if (!looper) { MWShowFailure(view, YES); return; }
    state[@"player"] = player;
    state[@"looper"] = looper;
    AVPlayerLayer *videoLayer = state[@"videoLayer"];
    videoLayer.player = player;
    MWUpdatePlayback(view);
}

static void MWLoadVideo(ScreenSaverView *view) {
    NSMutableDictionary *state = MWState(view);
    NSURL *url = state[@"videoURL"];
    if (!url || [state[@"failed"] boolValue]) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    state[@"asset"] = asset;
    unsigned long long generation = [state[@"generation"] unsignedLongLongValue];
    __weak ScreenSaverView *weakView = view;
    __weak AVURLAsset *weakAsset = asset;
    void (^finish)(BOOL) = ^(BOOL valid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ScreenSaverView *currentView = weakView;
            AVURLAsset *currentAsset = weakAsset;
            NSMutableDictionary *currentState = MWState(currentView);
            if (!currentView || !currentAsset || ![currentState[@"active"] boolValue]
                || [currentState[@"generation"] unsignedLongLongValue] != generation
                || currentState[@"asset"] != currentAsset) return;
            if (valid) MWInstallPlayer(currentView, currentAsset); else MWShowFailure(currentView, YES);
        });
    };
    // This remains the public asynchronous Objective-C API. Read the loaded
    // getters only after every requested property's status is Loaded.
    NSArray<NSString *> *keys = @[@"playable", @"duration"];
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        AVURLAsset *loadedAsset = weakAsset;
        if (!loadedAsset) return;
        for (NSString *key in keys) {
            if ([loadedAsset statusOfValueForKey:key error:nil] != AVKeyValueStatusLoaded) { finish(NO); return; }
        }
        CMTime duration = loadedAsset.duration;
        double seconds = CMTimeGetSeconds(duration);
        if (!loadedAsset.playable || !CMTIME_IS_NUMERIC(duration) || !isfinite(seconds) || seconds <= 0) {
            finish(NO);
            return;
        }
        [loadedAsset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
            finish(error == nil && tracks.count > 0);
        }];
    }];
}

static void MWPrepare(ScreenSaverView *view) {
    if (MWState(view)) return;
    AVPlayerLayer *videoLayer = [AVPlayerLayer layer];
    videoLayer.name = @"MyWallpaper.video";
    CALayer *posterLayer = [CALayer layer];
    posterLayer.name = @"MyWallpaper.poster";
    CATextLayer *messageLayer = [CATextLayer layer];
    messageLayer.name = @"MyWallpaper.message";
    messageLayer.alignmentMode = kCAAlignmentCenter;
    messageLayer.wrapped = YES;
    messageLayer.foregroundColor = NSColor.whiteColor.CGColor;
    messageLayer.hidden = YES;
    NSMutableDictionary *state = [@{@"videoLayer": videoLayer, @"posterLayer": posterLayer,
                                    @"messageLayer": messageLayer, @"generation": @0, @"active": @NO} mutableCopy];
    objc_setAssociatedObject(view, &MWStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.animationTimeInterval = 1;
    view.wantsLayer = YES;
    view.layer.backgroundColor = NSColor.blackColor.CGColor;
    view.layer.masksToBounds = YES;
    [view.layer addSublayer:videoLayer];
    [view.layer addSublayer:posterLayer];
    [view.layer addSublayer:messageLayer];
    view.needsLayout = YES;
    MWReadConfiguration(view);
}

// Initializer IMPs must explicitly preserve Objective-C init ownership: the
// incoming self is consumed and the result is returned at +1 under ARC.
typedef id (*MWFrameInitializer)(id __attribute__((ns_consumed)), SEL, NSRect, BOOL) __attribute__((ns_returns_retained));
typedef id (*MWCoderInitializer)(id __attribute__((ns_consumed)), SEL, NSCoder *) __attribute__((ns_returns_retained));

static id MWInitFrame(id view __attribute__((ns_consumed)), SEL selector, NSRect frame, BOOL preview) NS_RETURNS_RETAINED;
static id MWInitFrame(id view __attribute__((ns_consumed)), SEL selector, NSRect frame, BOOL preview) {
    MWFrameInitializer implementation = (MWFrameInitializer)class_getMethodImplementation(ScreenSaverView.class, selector);
    id initialized = implementation(view, selector, frame, preview);
    if (initialized) MWPrepare(initialized);
    return initialized;
}

static id MWInitCoder(id view __attribute__((ns_consumed)), SEL selector, NSCoder *coder) NS_RETURNS_RETAINED;
static id MWInitCoder(id view __attribute__((ns_consumed)), SEL selector, NSCoder *coder) {
    MWCoderInitializer implementation = (MWCoderInitializer)class_getMethodImplementation(ScreenSaverView.class, selector);
    id initialized = implementation(view, selector, coder);
    if (initialized) MWPrepare(initialized);
    return initialized;
}

static void MWStart(ScreenSaverView *view, SEL selector) {
    MWPrepare(view);
    NSMutableDictionary *state = MWState(view);
    if ([state[@"active"] boolValue]) return;
    state[@"active"] = @YES;
    state[@"generation"] = @([state[@"generation"] unsignedLongLongValue] + 1);
    MWCallSuper(view, selector);
    MWReadConfiguration(view);
    MWLoadVideo(view);
}

static void MWStop(ScreenSaverView *view, SEL selector) {
    NSMutableDictionary *state = MWState(view);
    state[@"active"] = @NO;
    state[@"generation"] = @([state[@"generation"] unsignedLongLongValue] + 1);
    MWReleasePlayback(state);
    MWCallSuper(view, selector);
}

static void MWAnimate(ScreenSaverView *view, SEL selector) {
    (void)selector;
    // ScreenSaver may deliver a late timer event after stopAnimation.
    MWUpdatePlayback(view);
}

static void MWLayout(ScreenSaverView *view, SEL selector) {
    MWCallSuper(view, selector);
    NSMutableDictionary *state = MWState(view);
    if (!state) return;
    CGRect bounds = view.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    AVPlayerLayer *videoLayer = state[@"videoLayer"];
    CALayer *posterLayer = state[@"posterLayer"];
    CATextLayer *messageLayer = state[@"messageLayer"];
    videoLayer.frame = bounds;
    posterLayer.frame = bounds;
    CGFloat inset = MIN(32, bounds.size.width / 10);
    CGFloat height = MIN(130, bounds.size.height);
    messageLayer.frame = CGRectMake(inset, (bounds.size.height - height) / 2,
                                    MAX(0, bounds.size.width - inset * 2), height);
    CGFloat scale = view.window ? view.window.backingScaleFactor : 2;
    messageLayer.contentsScale = scale;
    posterLayer.contentsScale = scale;
    [CATransaction commit];
}

static void MWDealloc(__unsafe_unretained id view, SEL selector) {
    // Do not retain a view which is already being deallocated. Associated
    // Foundation objects own the state; no custom observer class is necessary.
    NSMutableDictionary *state = MWState(view);
    MWReleasePlayback(state);
    objc_setAssociatedObject(view, &MWStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    MWCallSuper(view, selector);
}

static BOOL MWValidClassName(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    if ([name isEqualToString:@"MyWallpaperScreenSaverView"]) return YES;
    NSString *prefix = @"MyWallpaperSaver_";
    if (![name hasPrefix:prefix] || name.length != prefix.length + 32) return NO;
    NSString *suffix = [name substringFromIndex:prefix.length];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [suffix rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static BOOL MWAddMethod(Class cls, SEL selector, IMP implementation) {
    Method inherited = class_getInstanceMethod(ScreenSaverView.class, selector);
    return inherited && class_addMethod(cls, selector, implementation, method_getTypeEncoding(inherited));
}

__attribute__((constructor)) static void MWRegisterScreenSaver(void) {
    @autoreleasepool {
        Dl_info image = {0};
        if (!dladdr((const void *)&MWRegisterScreenSaver, &image) || !image.dli_fname) return;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:image.dli_fname]];
        for (NSUInteger i = 0; i < 3; i++) url = url.URLByDeletingLastPathComponent;
        MWBundleURL = url;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *name = info[@"NSPrincipalClass"];
        if (!MWValidClassName(name)) return;
        Class cls = objc_allocateClassPair(ScreenSaverView.class, name.UTF8String, 0);
        if (!cls) return;
        BOOL complete = MWAddMethod(cls, @selector(initWithFrame:isPreview:), (IMP)MWInitFrame)
            && MWAddMethod(cls, @selector(initWithCoder:), (IMP)MWInitCoder)
            && MWAddMethod(cls, @selector(startAnimation), (IMP)MWStart)
            && MWAddMethod(cls, @selector(stopAnimation), (IMP)MWStop)
            && MWAddMethod(cls, @selector(animateOneFrame), (IMP)MWAnimate)
            && MWAddMethod(cls, @selector(layout), (IMP)MWLayout)
            && MWAddMethod(cls, sel_registerName("dealloc"), (IMP)MWDealloc);
        if (complete) objc_registerClassPair(cls); else objc_disposeClassPair(cls);
    }
}
