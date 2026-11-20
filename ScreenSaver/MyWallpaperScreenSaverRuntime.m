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
    if ([state[@"linkedMode"] boolValue]) {
        message = russian
            ? @"MyWallpaper\nОткройте приложение и включите синхронизацию заставки с обоями."
            : @"MyWallpaper\nOpen the app and enable screen saver synchronization with your wallpaper.";
    } else if (invalidVideo) {
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

static void MWLoadVideo(ScreenSaverView *view);

// Linked installers embed a canonical absolute path. Never use home-directory
// APIs here: legacyScreenSaver remaps those APIs into its sandbox container.
static NSURL *MWLinkedRoot(id path) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]
        || [path pathComponents].count < 2 || [[path pathComponents] containsObject:@".."]
        || [[path pathComponents] containsObject:@"."]) return nil;
    NSURL *root = [NSURL fileURLWithPath:path isDirectory:YES];
    NSDictionary *values = [root resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] error:nil];
    if (![values[NSURLIsDirectoryKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]
        || ![root.URLByResolvingSymlinksInPath.path isEqualToString:root.path]) return nil;
    return root;
}

static NSURL *MWLinkedFile(NSURL *root, NSString *component) {
    NSURL *url = [root URLByAppendingPathComponent:component];
    NSDictionary *values = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey] error:nil];
    NSString *prefix = [root.path stringByAppendingString:@"/"];
    if (![values[NSURLIsRegularFileKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]
        || ![url.URLByResolvingSymlinksInPath.path hasPrefix:prefix]) return nil;
    return url;
}

static NSData *MWConfigurationData(NSURL *url) {
    NSNumber *size = [url resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey];
    if (!url || size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > 65536) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    return data.length > 0 && data.length <= 65536 ? data : nil;
}

static NSDictionary *MWParsedConfiguration(NSDictionary *json, NSURL *linkedRoot) {
    id version = json[@"version"];
    if ((linkedRoot && !version) || (version && version != NSNull.null
        && (![version isKindOfClass:NSNumber.class]
            || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID()
            || [version doubleValue] != 1))) return nil;
    if (linkedRoot && (!version || version == NSNull.null)) return nil;
    NSString *filename = json[@"videoFileName"];
    id scaling = json[@"scaling"];
    if (!linkedRoot && (!scaling || scaling == NSNull.null)) scaling = @"fill";
    if (![filename isKindOfClass:NSString.class] || ![@[@"video.mp4", @"video.mov"] containsObject:filename]
        || ![scaling isKindOfClass:NSString.class] || ![@[@"fill", @"fit"] containsObject:scaling]) return nil;
    BOOL valid = YES;
    if (linkedRoot) {
        for (NSString *key in @[@"animateOnBattery", @"animateOnExternalPower", @"pauseInLowPowerMode"])
            if (!json[key] || json[key] == NSNull.null) valid = NO;
    }
    BOOL battery = MWReadBoolean(json, @"animateOnBattery", NO, &valid);
    BOOL external = MWReadBoolean(json, @"animateOnExternalPower", YES, &valid);
    BOOL lowPower = MWReadBoolean(json, @"pauseInLowPowerMode", YES, &valid);
    NSURL *videoURL;
    NSURL *posterURL;
    if (linkedRoot) {
        NSString *revision = json[@"revision"];
        NSUUID *uuid = [revision isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:revision] : nil;
        if (!uuid || ![uuid.UUIDString isEqualToString:revision]) return nil;
        NSURL *directory = [linkedRoot URLByAppendingPathComponent:revision isDirectory:YES];
        NSDictionary *values = [directory resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey] error:nil];
        if (![values[NSURLIsDirectoryKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue]
            || ![directory.URLByResolvingSymlinksInPath.path isEqualToString:directory.path]) return nil;
        videoURL = MWLinkedFile(directory, filename);
        posterURL = MWLinkedFile(directory, @"poster.jpg");
    } else {
        videoURL = MWResource(filename);
        posterURL = MWResource(@"poster.jpg");
    }
    if (!valid || !videoURL || !posterURL) return nil;
    NSNumber *posterSize = [posterURL resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey];
    if (posterSize.unsignedLongLongValue == 0 || posterSize.unsignedLongLongValue > 32 * 1024 * 1024) return nil;
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:posterURL];
    if (![image CGImageForProposedRect:NULL context:nil hints:nil]) return nil;
    return @{@"configuration": @{@"animateOnBattery": @(battery), @"animateOnExternalPower": @(external),
                                  @"pauseInLowPowerMode": @(lowPower)},
             @"videoURL": videoURL, @"image": image, @"fit": @([scaling isEqualToString:@"fit"])};
}

static void MWApplyConfiguration(ScreenSaverView *view, NSDictionary *parsed) {
    NSMutableDictionary *state = MWState(view);
    state[@"configuration"] = parsed[@"configuration"];
    state[@"videoURL"] = parsed[@"videoURL"];
    state[@"failed"] = @NO;
    CATextLayer *messageLayer = state[@"messageLayer"];
    messageLayer.hidden = YES;
    AVPlayerLayer *videoLayer = state[@"videoLayer"];
    CALayer *posterLayer = state[@"posterLayer"];
    BOOL fit = [parsed[@"fit"] boolValue];
    videoLayer.videoGravity = fit ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResizeAspectFill;
    posterLayer.contentsGravity = fit ? kCAGravityResizeAspect : kCAGravityResizeAspectFill;
    NSImage *image = parsed[@"image"];
    posterLayer.contents = (__bridge id)[image CGImageForProposedRect:NULL context:nil hints:nil];
    posterLayer.hidden = NO;
    [state removeObjectForKey:@"appliedPlayback"];
}

static BOOL MWRefreshLinkedConfiguration(ScreenSaverView *view, BOOL allowLoad) {
    NSMutableDictionary *state = MWState(view);
    NSURL *root = MWLinkedRoot(state[@"linkedRootPath"]);
    NSData *data = root ? MWConfigurationData(MWLinkedFile(root, @"current.json")) : nil;
    if (!data) return NO;
    if ([data isEqualToData:state[@"linkedConfigurationData"]]) return YES;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *parsed = MWParsedConfiguration(decoded, root);
    if (!parsed) return NO;
    BOOL reloadVideo = ![parsed[@"videoURL"] isEqual:state[@"videoURL"]]
        || (!state[@"player"] && !state[@"asset"]);
    if (allowLoad && reloadVideo) {
        state[@"generation"] = @([state[@"generation"] unsignedLongLongValue] + 1);
        MWReleasePlayback(state);
    }
    MWApplyConfiguration(view, parsed);
    state[@"linkedConfigurationData"] = data;
    if (allowLoad && reloadVideo && [state[@"active"] boolValue]) MWLoadVideo(view);
    return YES;
}

static void MWReadConfiguration(ScreenSaverView *view) {
    NSMutableDictionary *state = MWState(view);
    state[@"failed"] = @NO;
    [state removeObjectsForKeys:@[@"configuration", @"videoURL", @"linkedRootPath", @"linkedConfigurationData", @"linkedMode"]];
    CATextLayer *messageLayer = state[@"messageLayer"];
    messageLayer.hidden = YES;
    CALayer *posterLayer = state[@"posterLayer"];
    posterLayer.contents = nil;
    posterLayer.hidden = NO;
    NSData *data = MWConfigurationData(MWResource(@"configuration.json"));
    id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![decoded isKindOfClass:NSDictionary.class]) { MWShowFailure(view, NO); return; }
    NSDictionary *json = decoded;
    id syncRootPath = json[@"syncRootPath"];
    if (syncRootPath && syncRootPath != NSNull.null) {
        state[@"linkedMode"] = @YES;
        if ([syncRootPath isKindOfClass:NSString.class]) state[@"linkedRootPath"] = syncRootPath;
        if (!MWRefreshLinkedConfiguration(view, NO)) MWShowFailure(view, NO);
    } else {
        NSDictionary *parsed = MWParsedConfiguration(json, nil);
        if (parsed) MWApplyConfiguration(view, parsed); else MWShowFailure(view, NO);
    }
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
    NSMutableDictionary *state = MWState(view);
    if (![state[@"active"] boolValue]) return;
    if ([state[@"linkedMode"] boolValue]) {
        // Keep the last valid frame/video during an incomplete or inaccessible
        // update. Initial failures remain visible and retry after the app publishes.
        MWRefreshLinkedConfiguration(view, YES);
    }
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
