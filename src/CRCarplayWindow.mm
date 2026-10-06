#include "common.h"
#include "CRCarplayWindow.h"

/*
Find the CADisplay handling the CarPlay stuff
*/
id getCarplayCADisplay(void)
{
    id carplayAVDisplay = objcInvoke(objc_getClass("AVExternalDevice"), @"currentCarPlayExternalDevice");
    if (!carplayAVDisplay)
    {
        return nil;
    }

    NSString *carplayDisplayUniqueID = objcInvoke(carplayAVDisplay, @"screenIDs")[0];
    for (id display in objcInvoke(objc_getClass("CADisplay"), @"displays"))
    {
        if ([carplayDisplayUniqueID isEqualToString:objcInvoke(display, @"uniqueId")])
        {
            return display;
        }
    }

    return nil;
}

@implementation CRCarPlayWindow

- (id)initWithBundleIdentifier:(id)identifier
{
    // Split-screen behavior:
    // SpringBoard's original hook calls -dismiss and then alloc/init when another
    // CarPlayEnable icon is tapped. Our -dismiss only hides the existing window,
    // so reuse it here and attach the newly selected app as App 2.
    id existingWindow = nil;
    @try
    {
        existingWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    }
    @catch (NSException *exception)
    {
        existingWindow = nil;
    }

    if (existingWindow && existingWindow != self && [existingWindow isKindOfClass:[CRCarPlayWindow class]])
    {
        NSString *primaryIdentifier = objcInvoke([existingWindow application], @"bundleIdentifier");
        NSString *secondaryIdentifier = nil;
        if ([existingWindow application2])
        {
            secondaryIdentifier = objcInvoke([existingWindow application2], @"bundleIdentifier");
        }

        if ([identifier isEqualToString:primaryIdentifier] || (secondaryIdentifier && [identifier isEqualToString:secondaryIdentifier]))
        {
            [existingWindow showCarPlayWindow];
        }
        else
        {
            [existingWindow setupSecondAppWithBundleIdentifier:identifier];
        }

        [self release];
        return existingWindow;
    }

    if ((self = [super init]))
    {
        _observers = [[NSMutableArray alloc] init];
        // Update this processes' preference cache
        [[CRPreferences sharedInstance] reloadPreferences];

        // Start in landscape
        self.orientation = 3;
        self.splitScreenEnabled = NO;
        self.splitRatio = 0.5f;

        self.sessionStatus = objcInvoke([objc_getClass("CARSessionStatus") alloc], @"initForCarPlayShell");

        self.application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
        assertGotExpectedObject(self.application, @"SBApplication");

        if (_drawOnMainScreen)
        {
            self.rootWindow = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
            ((void (*)(id, SEL, int, int, int, int))objc_msgSend)(self.rootWindow, NSSelectorFromString(@"_rotateWindowToOrientation:updateStatusBar:duration:skipCallbacks:"), 3, 1, 0, 0);
        }
        else
        {
            id carplayExternalDisplay = getCarplayCADisplay();
            assertGotExpectedObject(carplayExternalDisplay, @"CADisplay");

            id displayConfiguration = objcInvoke_2([objc_getClass("FBSDisplayConfiguration") alloc], @"initWithCADisplay:isMainDisplay:", carplayExternalDisplay, 0);
            assertGotExpectedObject(displayConfiguration, @"FBSDisplayConfiguration");

            // Create window on the Carplay screen
            self.rootWindow = objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);
        }

        [self.rootWindow.layer setCornerRadius:13.0f];
        [self.rootWindow.layer setMasksToBounds:YES];
        [self setupWallpaperBackground];
        [self setupDock];

        [self setupLiveAppView];

        // Add the user's wallpaper to the window. It will be visible when the app is in portrait mode
        CGRect rootWindowFrame = [[self rootWindow] frame];

        self.appContainerView = [[UIView alloc] initWithFrame:CGRectMake(CARPLAY_DOCK_WIDTH, rootWindowFrame.origin.y, rootWindowFrame.size.width - CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];
        [[self appContainerView] setBackgroundColor:[UIColor clearColor]];
        [[self appContainerView] setClipsToBounds:YES];
        [[self rootWindow] addSubview:[self appContainerView]];

        // The scene does not show a launch image, it needs to be created manually.
        [self setupLaunchImage];

        // Add the live app view
        [[self appContainerView] addSubview:objcInvoke(self.appViewController, @"view")];
        [self resizeAppViewForOrientation:self.orientation fullscreen:NO forceUpdate:YES];

        [[self rootWindow] setAlpha:0];
        [[self rootWindow] setHidden:0];

        // "unblank" the screen. This is necessary for animations/video to render when the device is locked.
        // This does not cause the screen to actually light up
        orig_BKSDisplayServicesSetScreenBlanked(0);

        [UIView animateWithDuration:1.0 animations:^(void)
        {
            [[self rootWindow] setAlpha:1];
        } completion:nil];

        // Add a placeholder "this app is on the carplay screen" view onto the app on the main screen
        id currentSceneHandle = objcInvoke(self.appViewController, @"sceneHandle");
        id mainSceneLayoutController = objcInvoke(objc_getClass("SBMainDisplaySceneLayoutViewController"), @"mainDisplaySceneLayoutViewController");
        id liveAppSceneControllers = objcInvoke(mainSceneLayoutController, @"appViewControllers");
        for (id appSceneLayoutController in liveAppSceneControllers)
        {
            id appSceneController = objcInvoke(appSceneLayoutController, @"_applicationSceneViewController");
            id appSceneView = objcInvoke(appSceneController, @"_sceneView");
            id appSceneHandle = objcInvoke(appSceneView, @"sceneHandle");
            if ([appSceneHandle isEqual:currentSceneHandle])
            {
                objcInvoke(appSceneView, @"drawCarplayPlaceholder");
            }
        }

        // Add observer the user changing the Dock's Alignment via preferences
        id observer = [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsDockAlignmentChanged queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            // Update this processes' preference cache
            [[CRPreferences sharedInstance] reloadPreferences];
            // Redraw the dock
            [self setupDock];
            // Relayout the app view
            [self resizeAppViewForOrientation:_orientation fullscreen:_isFullscreen forceUpdate:YES];
        }];
        [_observers addObject:observer];

        _screenTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleScreenTapped)];
        id systemGestureManager = objcInvoke(objc_getClass("_UISystemGestureManager"), @"sharedInstance");
        id identity = objcInvoke(objcInvoke(self.rootWindow, @"displayConfiguration"), @"identity");
        objcInvoke_2(systemGestureManager, @"addGestureRecognizer:toDisplayWithIdentity:", _screenTapRecognizer, identity);
    }

    return self;
}

- (void)setupWallpaperBackground
{
    CGRect rootWindowFrame = [[self rootWindow] frame];

    UIImageView *wallpaperImageView = [[UIImageView alloc] initWithFrame:rootWindowFrame];
    id defaultWallpaper = objcInvoke(objc_getClass("CRSUIWallpaperPreferences"), @"defaultWallpaper");
    assertGotExpectedObject(defaultWallpaper, @"CRSUIWallpaper");

    UIImage *wallpaperImage = objcInvoke_1(defaultWallpaper, @"wallpaperImageCompatibleWithTraitCollection:", nil);
    [wallpaperImageView setImage:wallpaperImage];
    UIVisualEffectView *wallpaperBlurView = [[UIVisualEffectView alloc] initWithEffect:objcInvoke_1(objc_getClass("UIBlurEffect"), @"effectWithBlurRadius:", 10.0)];
    [wallpaperBlurView setFrame:rootWindowFrame];
    [wallpaperImageView addSubview:wallpaperBlurView];
    [[self rootWindow] addSubview:wallpaperImageView];
}

- (void)setupDock
{
    // If the dock already exists, remove it. This allows the dock to be redrawn easily if the user switches the alignment
    if (_dockView)
    {
        [_dockView removeFromSuperview];
    }

    CGRect rootWindowFrame = [[self rootWindow] frame];
    BOOL rightHandDock = [self shouldUseRightHandDock];

    CGFloat dockXOrigin = (rightHandDock) ? rootWindowFrame.size.width - CARPLAY_DOCK_WIDTH : 0;
    self.dockView = [[UIView alloc] initWithFrame:CGRectMake(dockXOrigin, rootWindowFrame.origin.y, CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];

    // Setup dock visual effects
    id blurEffect = objcInvoke_1(objc_getClass("UIBlurEffect"), @"effectWithBlurRadius:", 20.0);
    UIVisualEffectView *effectsView = [[UIVisualEffectView alloc] init];
    [effectsView setFrame:CGRectMake(0, 0, CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];
    id colorEffect = objcInvoke_1(objc_getClass("UIColorEffect"), @"colorEffectSaturate:", 2.0);
    id darkEffect = objcInvoke_3(objc_getClass("UIVisualEffect"), @"effectCompositingColor:withMode:alpha:", [UIColor blackColor], 7, 0.6);
    NSArray *effects = @[darkEffect, colorEffect, blurEffect];
    objcInvoke_1(effectsView, @"setBackgroundEffects:", effects);
    [self.dockView addSubview:effectsView];

    [[self rootWindow] addSubview:self.dockView];

    NSBundle *carplayBundle = [NSBundle bundleWithPath:@"/System/Library/CoreServices/CarPlay.app"];
    UITraitCollection *carplayTrait = [UITraitCollection traitCollectionWithUserInterfaceIdiom:(UIUserInterfaceIdiom)3];
    UITraitCollection *interfaceStyleTrait = [UITraitCollection traitCollectionWithUserInterfaceStyle:(UIUserInterfaceStyle)1];
    UITraitCollection *traitCollection = [UITraitCollection traitCollectionWithTraitsFromCollections:@[carplayTrait, interfaceStyleTrait]];

    CGFloat buttonSize = 35;
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *homeButtonLightImage = [[UIImage imageNamed:@"CarStatusBarIconsHomeButton" inBundle:carplayBundle compatibleWithTraitCollection:traitCollection] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [closeButton setImage:homeButtonLightImage forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [closeButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, rootWindowFrame.size.height - buttonSize, buttonSize, buttonSize)];
    [closeButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:closeButton];

    id imageConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightLight];

    // X = fully close both hosted apps. The Home button above only hides this
    // overlay so the user can pick the second app from the CarPlay dashboard.
    UIButton *hardCloseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [hardCloseButton setImage:[UIImage systemImageNamed:@"xmark.circle" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [hardCloseButton addTarget:self action:@selector(hardDismiss) forControlEvents:UIControlEventTouchUpInside];
    [hardCloseButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - 30) / 2, rootWindowFrame.size.height - buttonSize - 38, 30, 30)];
    [hardCloseButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:hardCloseButton];

    buttonSize = 30;

    UIButton *fullscreenButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [fullscreenButton setImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [fullscreenButton addTarget:self action:@selector(enterFullscreen) forControlEvents:UIControlEventTouchUpInside];
    [fullscreenButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, 10, buttonSize, buttonSize)];
    [fullscreenButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:fullscreenButton];

    UIButton *rotateButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [rotateButton setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [rotateButton addTarget:self action:@selector(handleRotate) forControlEvents:UIControlEventTouchUpInside];
    [rotateButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, fullscreenButton.frame.origin.y + 10 + buttonSize, buttonSize, buttonSize)];
    [rotateButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:rotateButton];
}

- (void)setupLaunchImage
{
    LOG_LIFECYCLE_EVENT;
    // Fetch a snapshot to use
    id launchImageSnapshotManifest = objcInvoke_1([objc_getClass("XBApplicationSnapshotManifest") alloc], @"initWithApplicationInfo:", objcInvoke(self.application, @"info"));
    // There's a few variants of snapshots offered: portait/landscape, dark/light.
    // For now just try to find a landscape snapshot. If no landscape, fallback to portait.
    id appSnapshot = nil;
    for (id snapshotGroup in objcInvoke(launchImageSnapshotManifest, @"_allSnapshotGroups"))
    {
        for (id snapshotCandidate in objcInvoke(snapshotGroup, @"snapshots"))
        {
            int snapshotOrientation = objcInvokeT(snapshotCandidate, @"interfaceOrientation", int);
            int snapshotContentType = objcInvokeT(snapshotCandidate, @"contentType", int);
            if (UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)snapshotOrientation))
            {
                BOOL isSceneContent = snapshotContentType == 0;
                if (!appSnapshot && isSceneContent)
                {
                    if ([objcInvoke(snapshotCandidate, @"name") isEqualToString:@"CarPlayLaunchImage"])
                    {
                        appSnapshot = snapshotCandidate;
                        break;
                    }
                }

                BOOL isStaticOrGeneratedImage = (snapshotContentType == 1 || snapshotContentType == 2);
                if (isStaticOrGeneratedImage)
                {
                    appSnapshot = snapshotCandidate;
                    break;
                }
            }

            // Portait, but better than nothing
            if (!appSnapshot)
            {
                appSnapshot = snapshotCandidate;
            }
        }
    }
    // If no landscape image was found, queue up a snapshot once the app launches
    self.shouldGenerateSnapshot = UIInterfaceOrientationIsPortrait((UIInterfaceOrientation)objcInvokeT(appSnapshot, @"interfaceOrientation", int));

    // Get the image from the chosen snapshot
    id appSnapshotImage = objcInvoke_1(appSnapshot, @"imageForInterfaceOrientation:", 1);

    // Build an imageview to contain the launch image.
    // The processLaunched handler defined above is responsible for cleaning this up
    self.launchImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, [[self appContainerView] frame].size.width, [[self appContainerView] frame].size.height)];
    [self.launchImageView setImage:appSnapshotImage];
    [self.launchImageView setContentMode:UIViewContentModeScaleToFill];
    [[self appContainerView] addSubview:self.launchImageView];
}

- (void)setupLiveAppView
{
    LOG_LIFECYCLE_EVENT;
    NSString *appIdentifier = objcInvoke(self.application, @"bundleIdentifier");

    NSMutableArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
    [lockAssertions addObject:appIdentifier];

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    assertGotExpectedObject(displaySceneManager, @"SBMainDisplaySceneManager");

    id sceneLayoutManager = objcInvoke(displaySceneManager, @"_layoutStateManager");
    assertGotExpectedObject(sceneLayoutManager, @"SBMainDisplayLayoutStateManager");

    id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");
    assertGotExpectedObject(mainScreenIdentity, @"FBSDisplayIdentity");

    id sceneIdentity = objcInvoke_2(displaySceneManager, @"_sceneIdentityForApplication:createPrimaryIfRequired:", self.application, 1);
    assertGotExpectedObject(sceneIdentity, @"FBSSceneIdentity");

    id sceneHandleRequest = objcInvoke_3(objc_getClass("SBApplicationSceneHandleRequest"), @"defaultRequestForApplication:sceneIdentity:displayIdentity:", self.application, sceneIdentity, mainScreenIdentity);
    assertGotExpectedObject(sceneHandleRequest, @"SBApplicationSceneHandleRequest");

    id sceneHandle = objcInvoke_1(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
    assertGotExpectedObject(sceneHandle, @"SBDeviceApplicationSceneHandle");

    id appSceneEntity = objcInvoke_1([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);
    assertGotExpectedObject(appSceneEntity, @"SBDeviceApplicationSceneEntity");

    self.appViewController = objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:", appIdentifier, appSceneEntity);
    assertGotExpectedObject(self.appViewController, @"SBAppViewController");
    objcInvoke_1(self.appViewController, @"setIgnoresOcclusions:", 0);
    setIvar(self.appViewController, @"_currentMode", @(2));
    objcInvoke(getIvar(self.appViewController, @"_activationSettings"), @"clearActivationSettings");

    id sceneUpdateTransaction = objcInvoke_2(self.appViewController, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", appSceneEntity, 1);
    assertGotExpectedObject(sceneUpdateTransaction, @"SBApplicationSceneUpdateTransaction");

    __block NSMutableArray *transactions = getIvar(self.appViewController, @"_activeTransitions");
    objcInvoke_1(sceneUpdateTransaction, @"setCompletionBlock:", ^void(int arg1) {

        [transactions removeObject:sceneUpdateTransaction];

        id processLaunchTransaction = getIvar(sceneUpdateTransaction, @"_processLaunchTransaction");
        assertGotExpectedObject(processLaunchTransaction, @"FBApplicationProcessLaunchTransaction");

        id appProcess = objcInvoke(processLaunchTransaction, @"process");
        assertGotExpectedObject(appProcess, @"FBProcess");

        objcInvoke_1(appProcess, @"_executeBlockAfterLaunchCompletes:", ^void(void) {
            // Wait a sec then remove the splashscreen image. It should already be hidden/covered by the live app view, but it needs to be removed
            // so it doesn't poke through if the App's orientation changes to portait
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self.launchImageView removeFromSuperview];

                if (self.shouldGenerateSnapshot)
                {
                    // Now that the app is launched and presumably in landscape mode, save a snapshot.
                    // If an app does not natively support landscape mode and doesn't ship a landscape launch image, this snapshot can be used during cold-launches
                    id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
                    if (!appScene)
                    {
                        return;
                    }
                    id sceneSettings = objcInvoke(appScene, @"mutableSettings");
                    objcInvoke_1(sceneSettings, @"setInterfaceOrientation:", self.orientation);
                    id snapshotContext = objcInvoke_2(objc_getClass("FBSSceneSnapshotContext"), @"contextWithSceneID:settings:", objcInvoke(appScene, @"identifier"), sceneSettings);
                    objcInvoke_1(snapshotContext, @"setName:", @"CarPlayLaunchImage");
                    objcInvoke_1(snapshotContext, @"setScale:", 2);
                    objcInvoke_1(snapshotContext, @"setExpirationInterval:", 99999);
                    objcInvoke_3(self.application, @"saveSnapshotForSceneHandle:context:completion:", sceneHandle, snapshotContext, nil);
                }
            });

            // Ask the app to rotate to landscape
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:appIdentifier userInfo:@{@"orientation": @(self.orientation)}];
        });
    });

    [transactions addObject:sceneUpdateTransaction];
    objcInvoke(sceneUpdateTransaction, @"begin");
    objcInvoke(self.appViewController, @"_createSceneViewController");

    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    assertGotExpectedObject(animationFactory, @"BSUIAnimationFactory");

    id appView = objcInvoke(self.appViewController, @"appView");
    objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", 4, animationFactory, 0);
    [[self.appViewController view] setBackgroundColor:[UIColor clearColor]];

    // Create a scene monitor to watch for the app process dying. The carplay window will dismiss itself.
    // todo: this returns nil if the app process isn't running..
    NSString *sceneID = objcInvoke_1(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:", appIdentifier);
    self.sceneMonitor = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
    objcInvoke_1(self.sceneMonitor, @"setDelegate:", self);
}


/*
Show the already-hosted CarPlay window again after the user picked App 2.
*/
- (void)showCarPlayWindow
{
    if (!self.rootWindow)
    {
        return;
    }

    [self.rootWindow setAlpha:1.0];
    [self.rootWindow setHidden:NO];
    if (self.dockView)
    {
        [self.rootWindow bringSubviewToFront:self.dockView];
    }
}

/*
Restore a hosted application scene back to normal iPhone behavior and release
the lock assertion that kept it active while shown on CarPlay.
*/
- (void)releaseHostedAppViewController:(id)viewController
{
    if (!viewController)
    {
        return;
    }

    int resetOrientationLock = -1;
    NSString *hostedIdentifier = getIvar(viewController, @"_identifier");
    if (hostedIdentifier)
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
            postNotificationName:@"com.carplayenable.orientation"
            object:hostedIdentifier
            userInfo:@{@"orientation": @(resetOrientationLock)}];
    }

    objcInvoke_1(viewController, @"_setCurrentMode:", 0);

    // Restore the main-screen counterpart from Placeholder to LiveContent.
    id currentSceneHandle = objcInvoke(viewController, @"sceneHandle");
    id mainSceneLayoutController = objcInvoke(objc_getClass("SBMainDisplaySceneLayoutViewController"), @"mainDisplaySceneLayoutViewController");
    id liveAppSceneControllers = objcInvoke(mainSceneLayoutController, @"appViewControllers");
    for (id appSceneLayoutController in liveAppSceneControllers)
    {
        id appSceneController = objcInvoke(appSceneLayoutController, @"_applicationSceneViewController");
        id appSceneView = objcInvoke(appSceneController, @"_sceneView");
        id appSceneHandle = objcInvoke(appSceneView, @"sceneHandle");
        if ([appSceneHandle isEqual:currentSceneHandle])
        {
            objcInvoke_3(appSceneView, @"setDisplayMode:animationFactory:completion:", 4, nil, nil);
        }
    }

    id sharedApp = [UIApplication sharedApplication];
    NSMutableArray *lockAssertions = objc_getAssociatedObject(sharedApp, &kPropertyKey_lockAssertionIdentifiers);
    id appScene = objcInvoke(currentSceneHandle, @"sceneIfExists");
    if (appScene != nil)
    {
        NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");

        // Remove this before asking FBScene to background; the SpringBoard hook
        // intentionally blocks backgrounding while an identifier is asserted.
        if (sceneAppBundleID)
        {
            [lockAssertions removeObject:sceneAppBundleID];
        }

        id frontmostApp = objcInvoke(sharedApp, @"_accessibilityFrontMostApplication");
        BOOL isAppOnMainScreen = frontmostApp && [objcInvoke(frontmostApp, @"bundleIdentifier") isEqualToString:sceneAppBundleID];
        if (!isAppOnMainScreen)
        {
            id sceneSettings = objcInvoke(appScene, @"mutableSettings");
            objcInvoke_1(sceneSettings, @"setBackgrounded:", 1);
            objcInvoke_1(sceneSettings, @"setForeground:", 0);
            ((void (*)(id, SEL, id, id, void *))objc_msgSend)(
                appScene,
                NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"),
                sceneSettings,
                nil,
                0
            );
        }
    }
}

/*
Remove only App 2. App 1 stays hosted.
*/
- (void)teardownSecondApp
{
    if (!self.appViewController2)
    {
        self.splitScreenEnabled = NO;
        return;
    }

    [self.sceneMonitor2 invalidate];
    [self releaseHostedAppViewController:self.appViewController2];

    [[self.appViewController2 view] removeFromSuperview];
    [self.appContainerView2 removeFromSuperview];

    self.sceneMonitor2 = nil;
    self.appViewController2 = nil;
    self.application2 = nil;
    self.appContainerView2 = nil;
    self.splitScreenEnabled = NO;

    // Remove dock split buttons
    [[self.dockView viewWithTag:9101] removeFromSuperview];
    [[self.dockView viewWithTag:9102] removeFromSuperview];
    [[self.dockView viewWithTag:9103] removeFromSuperview];
}

- (void)setupSecondAppWithBundleIdentifier:(NSString *)identifier
{
    LOG_LIFECYCLE_EVENT;

    if (!identifier || [identifier length] == 0)
    {
        [self showCarPlayWindow];
        return;
    }

    NSString *primaryIdentifier = objcInvoke(self.application, @"bundleIdentifier");
    if ([identifier isEqualToString:primaryIdentifier])
    {
        [self showCarPlayWindow];
        return;
    }

    NSString *currentSecondaryIdentifier = self.application2 ? objcInvoke(self.application2, @"bundleIdentifier") : nil;
    if (currentSecondaryIdentifier && [identifier isEqualToString:currentSecondaryIdentifier])
    {
        [self showCarPlayWindow];
        return;
    }

    // A third selection replaces the existing right-hand app.
    [self teardownSecondApp];

    self.application2 = objcInvoke_1(
        objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"),
        @"applicationWithBundleIdentifier:",
        identifier
    );
    assertGotExpectedObject(self.application2, @"SBApplication");

    NSString *appIdentifier = objcInvoke(self.application2, @"bundleIdentifier");

    NSMutableArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
    if (![lockAssertions containsObject:appIdentifier])
    {
        [lockAssertions addObject:appIdentifier];
    }

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    assertGotExpectedObject(displaySceneManager, @"SBMainDisplaySceneManager");

    id sceneLayoutManager = objcInvoke(displaySceneManager, @"_layoutStateManager");
    assertGotExpectedObject(sceneLayoutManager, @"SBMainDisplayLayoutStateManager");

    id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");
    assertGotExpectedObject(mainScreenIdentity, @"FBSDisplayIdentity");

    id sceneIdentity = objcInvoke_2(
        displaySceneManager,
        @"_sceneIdentityForApplication:createPrimaryIfRequired:",
        self.application2,
        1
    );
    assertGotExpectedObject(sceneIdentity, @"FBSSceneIdentity");

    id sceneHandleRequest = objcInvoke_3(
        objc_getClass("SBApplicationSceneHandleRequest"),
        @"defaultRequestForApplication:sceneIdentity:displayIdentity:",
        self.application2,
        sceneIdentity,
        mainScreenIdentity
    );
    assertGotExpectedObject(sceneHandleRequest, @"SBApplicationSceneHandleRequest");

    id sceneHandle = objcInvoke_1(
        displaySceneManager,
        @"fetchOrCreateApplicationSceneHandleForRequest:",
        sceneHandleRequest
    );
    assertGotExpectedObject(sceneHandle, @"SBDeviceApplicationSceneHandle");

    id appSceneEntity = objcInvoke_1(
        [objc_getClass("SBDeviceApplicationSceneEntity") alloc],
        @"initWithApplicationSceneHandle:",
        sceneHandle
    );
    assertGotExpectedObject(appSceneEntity, @"SBDeviceApplicationSceneEntity");

    self.appViewController2 = objcInvoke_2(
        [objc_getClass("SBAppViewController") alloc],
        @"initWithIdentifier:andApplicationSceneEntity:",
        appIdentifier,
        appSceneEntity
    );
    assertGotExpectedObject(self.appViewController2, @"SBAppViewController");

    objcInvoke_1(self.appViewController2, @"setIgnoresOcclusions:", 0);
    setIvar(self.appViewController2, @"_currentMode", @(2));
    objcInvoke(getIvar(self.appViewController2, @"_activationSettings"), @"clearActivationSettings");

    id sceneUpdateTransaction = objcInvoke_2(
        self.appViewController2,
        @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:",
        appSceneEntity,
        1
    );
    assertGotExpectedObject(sceneUpdateTransaction, @"SBApplicationSceneUpdateTransaction");

    __block NSMutableArray *transactions = getIvar(self.appViewController2, @"_activeTransitions");
    objcInvoke_1(sceneUpdateTransaction, @"setCompletionBlock:", ^void(int arg1) {
        [transactions removeObject:sceneUpdateTransaction];

        id processLaunchTransaction = getIvar(sceneUpdateTransaction, @"_processLaunchTransaction");
        if (processLaunchTransaction)
        {
            id appProcess = objcInvoke(processLaunchTransaction, @"process");
            if (appProcess)
            {
                objcInvoke_1(appProcess, @"_executeBlockAfterLaunchCompletes:", ^void(void) {
                    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                        postNotificationName:@"com.carplayenable.orientation"
                        object:appIdentifier
                        userInfo:@{@"orientation": @(self.orientation)}];
                });
            }
        }
    });

    [transactions addObject:sceneUpdateTransaction];
    objcInvoke(sceneUpdateTransaction, @"begin");
    objcInvoke(self.appViewController2, @"_createSceneViewController");

    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    assertGotExpectedObject(animationFactory, @"BSUIAnimationFactory");

    id appView = objcInvoke(self.appViewController2, @"appView");
    objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", 4, animationFactory, 0);
    [[self.appViewController2 view] setBackgroundColor:[UIColor clearColor]];

    NSString *sceneID = objcInvoke_1(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:", appIdentifier);
    self.sceneMonitor2 = objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID);
    objcInvoke_1(self.sceneMonitor2, @"setDelegate:", self);

    CGRect rootWindowFrame = [[self rootWindow] frame];
    self.appContainerView2 = [[UIView alloc] initWithFrame:rootWindowFrame];
    [self.appContainerView2 setBackgroundColor:[UIColor clearColor]];
    [self.appContainerView2 setClipsToBounds:YES];
    [self.rootWindow addSubview:self.appContainerView2];
    [self.appContainerView2 addSubview:[self.appViewController2 view]];

    self.splitScreenEnabled = YES;
    // Quick split controls on CarPlay Dock
    if ([self.dockView viewWithTag:9101] == nil) {
        UIButton *app1Toggle = [UIButton buttonWithType:UIButtonTypeSystem];
        app1Toggle.tag = 9101;
        app1Toggle.frame = CGRectMake(8, 95, 42, 38);
        [app1Toggle setTitle:@"[1]" forState:UIControlStateNormal];
        [app1Toggle setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        app1Toggle.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
        app1Toggle.layer.cornerRadius = 6;
        app1Toggle.clipsToBounds = YES;
        [app1Toggle addTarget:self action:@selector(toggleFirstSplitApp) forControlEvents:UIControlEventTouchUpInside];
        [self.dockView addSubview:app1Toggle];
    }

    if ([self.dockView viewWithTag:9102] == nil) {
        UIButton *app2Toggle = [UIButton buttonWithType:UIButtonTypeSystem];
        app2Toggle.tag = 9102;
        app2Toggle.frame = CGRectMake(8, 138, 42, 38);
        [app2Toggle setTitle:@"[2]" forState:UIControlStateNormal];
        [app2Toggle setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        app2Toggle.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
        app2Toggle.layer.cornerRadius = 6;
        app2Toggle.clipsToBounds = YES;
        [app2Toggle addTarget:self action:@selector(toggleSecondSplitApp) forControlEvents:UIControlEventTouchUpInside];
        [self.dockView addSubview:app2Toggle];
    }

    if ([self.dockView viewWithTag:9103] == nil) {
        UIButton *ratioToggle = [UIButton buttonWithType:UIButtonTypeSystem];
        ratioToggle.tag = 9103;
        ratioToggle.frame = CGRectMake(8, 181, 42, 38);
        [ratioToggle setTitle:@"5:5" forState:UIControlStateNormal];
        [ratioToggle setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        ratioToggle.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
        ratioToggle.layer.cornerRadius = 6;
        ratioToggle.clipsToBounds = YES;
        [ratioToggle addTarget:self action:@selector(toggleSplitRatio) forControlEvents:UIControlEventTouchUpInside];
        [self.dockView addSubview:ratioToggle];
    }


    // Draw the same main-screen placeholder used by App 1.
    id currentSceneHandle = objcInvoke(self.appViewController2, @"sceneHandle");
    id mainSceneLayoutController = objcInvoke(objc_getClass("SBMainDisplaySceneLayoutViewController"), @"mainDisplaySceneLayoutViewController");
    id liveAppSceneControllers = objcInvoke(mainSceneLayoutController, @"appViewControllers");
    for (id appSceneLayoutController in liveAppSceneControllers)
    {
        id appSceneController = objcInvoke(appSceneLayoutController, @"_applicationSceneViewController");
        id appSceneView = objcInvoke(appSceneController, @"_sceneView");
        id appSceneHandle = objcInvoke(appSceneView, @"sceneHandle");
        if ([appSceneHandle isEqual:currentSceneHandle])
        {
            objcInvoke(appSceneView, @"drawCarplayPlaceholder");
        }
    }

    [self resizeAppViewForOrientation:self.orientation fullscreen:self.isFullscreen forceUpdate:YES];
    [self showCarPlayWindow];
}

/*
FBSceneMonitor delegate method, invoked when the app process dies.
Use this to close the window on the CarPlay screen if the app crashes or is killed via the App Switcher on main screen
*/
- (void)sceneMonitor:(id)arg1 sceneWasDestroyed:(id)arg2
{
    LOG_LIFECYCLE_EVENT;
    // A hosted process really died; fully tear down the split session.
    objcInvoke(self, @"hardDismiss");
}

- (void)handleScreenTapped
{
    LOG_LIFECYCLE_EVENT;
    // The carplay screen was tapped.
    // If the window is fullscreen'd, exit fullscreen
    if (_isFullscreen)
    {
        [self exitFullscreen];
    }
}

- (void)exitFullscreen
{
    LOG_LIFECYCLE_EVENT;
    if (_isFullscreen)
    {
        [self resizeAppViewForOrientation:self.orientation fullscreen:NO forceUpdate:NO];
    }
}

- (void)enterFullscreen
{
    LOG_LIFECYCLE_EVENT;
    // Only need fullscreen when in landscape
    if (UIInterfaceOrientationIsPortrait((UIInterfaceOrientation)self.orientation))
    {
        return;
    }

    BOOL toFullScreen = 1;
    [UIView animateWithDuration:0.2 animations:^(void) {
        [self resizeAppViewForOrientation:self.orientation fullscreen:toFullScreen forceUpdate:NO];
    } completion:nil];
}

/*
Home behavior for the split build.
Keep App 1 alive, hide the overlay, and reveal the CarPlay dashboard so the
user can choose App 2. SpringBoard will still call this before launching a
new CarPlayEnable icon; initWithBundleIdentifier: will then reuse this object.
*/
- (void)dismiss
{
    LOG_LIFECYCLE_EVENT;

    // On a real CarPlay disconnect there is no display left to come back to.
    if (!getCarplayCADisplay())
    {
        [self hardDismiss];
        return;
    }

    [self.rootWindow setHidden:YES];
}

/*
Fully close both hosted apps and restore the original CarPlayEnable lifecycle.
Use the X button in the custom dock to call this.
*/
- (void)hardDismiss
{
    LOG_LIFECYCLE_EVENT;

    [self.sceneMonitor invalidate];
    [self.sceneMonitor2 invalidate];

    for (id observer in _observers)
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] removeObserver:observer];
    }

    id systemGestureManager = objcInvoke(objc_getClass("_UISystemGestureManager"), @"sharedInstance");
    if (self.rootWindow)
    {
        id identity = objcInvoke(objcInvoke(self.rootWindow, @"displayConfiguration"), @"identity");
        if (identity)
        {
            objcInvoke_2(systemGestureManager, @"removeGestureRecognizer:fromDisplayWithIdentity:", _screenTapRecognizer, identity);
        }
    }

    void (^cleanupAfterCarplay)() = ^() {
        [self releaseHostedAppViewController:self.appViewController2];
        [self releaseHostedAppViewController:self.appViewController];

        id sharedApp = [UIApplication sharedApplication];

        if (objcInvokeT(sharedApp, @"isLocked", BOOL) == YES)
        {
            void *_BKSHIDServicesGetBacklightFactor = dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
            if (_BKSHIDServicesGetBacklightFactor)
            {
                float backlightFactor = ((float (*)(void))_BKSHIDServicesGetBacklightFactor)();
                if (backlightFactor < 0.2)
                {
                    orig_BKSDisplayServicesSetScreenBlanked(1);
                }
            }
        }

        objc_setAssociatedObject(sharedApp, &kPropertyKey_liveCarplayWindow, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [self.appContainerView2 removeFromSuperview];
        self.appContainerView2 = nil;
        self.appViewController2 = nil;
        self.application2 = nil;
        self.sceneMonitor2 = nil;
        self.splitScreenEnabled = NO;

        [self.rootWindow setHidden:YES];
        [self.rootWindow removeFromSuperview];
        [self.rootWindow release];
        self.rootWindow = nil;
    };

    if (!self.rootWindow)
    {
        cleanupAfterCarplay();
        return;
    }

    [UIView animateWithDuration:0.25 animations:^(void)
    {
        [self.rootWindow setAlpha:0];
    } completion:^(BOOL completed)
    {
        cleanupAfterCarplay();
    }];
}

/*
When the "rotate orientation" button is pressed on a CarplayEnabled app window
*/
- (void)handleRotate
{
    LOG_LIFECYCLE_EVENT;
    int desiredOrientation = (UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)self.orientation)) ? 1 : 3;

    id appScene = objcInvoke(objcInvoke([self appViewController], @"sceneHandle"), @"sceneIfExists");
    if (!appScene)
    {
        return;
    }

    NSString *sceneAppBundleID = objcInvoke(objcInvoke(objcInvoke(appScene, @"client"), @"process"), @"bundleIdentifier");
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
        postNotificationName:@"com.carplayenable.orientation"
        object:sceneAppBundleID
        userInfo:@{@"orientation": @(desiredOrientation)}];

    if (self.appViewController2)
    {
        id appScene2 = objcInvoke(objcInvoke([self appViewController2], @"sceneHandle"), @"sceneIfExists");
        if (appScene2)
        {
            NSString *sceneAppBundleID2 = objcInvoke(objcInvoke(objcInvoke(appScene2, @"client"), @"process"), @"bundleIdentifier");
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter]
                postNotificationName:@"com.carplayenable.orientation"
                object:sceneAppBundleID2
                userInfo:@{@"orientation": @(desiredOrientation)}];
        }
    }

    [self resizeAppViewForOrientation:desiredOrientation fullscreen:self.isFullscreen forceUpdate:NO];
}

/*
Handle resizing the Carplay App window. Called anytime the app orientation changes (including first appearance)
*/
- (void)resizeAppViewForOrientation:(int)desiredOrientation fullscreen:(BOOL)fullscreen forceUpdate:(BOOL)forceUpdate
{
    LOG_LIFECYCLE_EVENT;
    if (!forceUpdate && (desiredOrientation == self.orientation && self.isFullscreen == fullscreen))
    {
        return;
    }

    UIScreen *targetScreen = nil;
    if (_drawOnMainScreen)
    {
        targetScreen = [UIScreen mainScreen];
    }
    else
    {
        for (UIScreen *currentScreen in [UIScreen screens])
        {
            if (objcInvokeT(currentScreen, @"_isCarScreen", BOOL))
            {
                targetScreen = currentScreen;
                break;
            }
        }
    }

    assertGotExpectedObject(targetScreen, @"UIScreen");

    CGRect carplayDisplayBounds = [targetScreen bounds];
    CGFloat dockWidth = (fullscreen) ? 0 : CARPLAY_DOCK_WIDTH;
    BOOL rightHandDock = [self shouldUseRightHandDock];

    if (self.splitScreenEnabled && self.appViewController2 && self.appContainerView2)
    {
        // Two equal interactive regions, with a tiny gap so it is obvious that
        // these are separate application surfaces.
        CGFloat usableWidth = carplayDisplayBounds.size.width - dockWidth;
        CGFloat gap = 2.0f;
        CGFloat ratio = (self.splitRatio > 0.15f && self.splitRatio < 0.85f) ? self.splitRatio : 0.5f;
        CGFloat leftWidth = (usableWidth - gap) * ratio;
        CGFloat rightWidth = usableWidth - gap - leftWidth;
        CGFloat baseX = rightHandDock ? 0 : dockWidth;

        CGRect leftFrame = CGRectMake(baseX, 0, leftWidth, carplayDisplayBounds.size.height);
        CGRect rightFrame = CGRectMake(baseX + leftWidth + gap, 0, rightWidth, carplayDisplayBounds.size.height);

        [self.appContainerView setFrame:leftFrame];
        [self.appContainerView2 setFrame:rightFrame];
        [self.appContainerView setClipsToBounds:YES];
        [self.appContainerView2 setClipsToBounds:YES];

        CGSize mainScreenSize = ((CGRect (*)(id, SEL, int))objc_msgSend)(
            [UIScreen mainScreen],
            NSSelectorFromString(@"boundsForOrientation:"),
            desiredOrientation
        ).size;

        NSArray *controllers = @[self.appViewController, self.appViewController2];
        NSArray *containers = @[self.appContainerView, self.appContainerView2];

        for (NSUInteger i = 0; i < [controllers count]; i++)
        {
            id controller = [controllers objectAtIndex:i];
            UIView *container = [containers objectAtIndex:i];

            id appSceneView = getIvar(getIvar(controller, @"_deviceAppViewController"), @"_sceneView");
            assertGotExpectedObject(appSceneView, @"SBSceneView");
            UIView *hostingContentView = getIvar(appSceneView, @"_sceneContentContainerView");

            CGSize regionSize = [container bounds].size;
            CGFloat widthScale = regionSize.width / mainScreenSize.width;
            CGFloat heightScale = regionSize.height / mainScreenSize.height;

            [hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
            [[controller view] setFrame:[container bounds]];
        }

        [self.dockView setAlpha:(fullscreen) ? 0 : 1];
        if (self.dockView)
        {
            [self.rootWindow bringSubviewToFront:self.dockView];
        }

        self.orientation = desiredOrientation;
        self.isFullscreen = fullscreen;
        return;
    }

    // Original single-app layout.
    id appSceneView = getIvar(getIvar(self.appViewController, @"_deviceAppViewController"), @"_sceneView");
    assertGotExpectedObject(appSceneView, @"SBSceneView");
    UIView *hostingContentView = getIvar(appSceneView, @"_sceneContentContainerView");

    CGSize carplayDisplaySize = CGSizeMake(carplayDisplayBounds.size.width - dockWidth, carplayDisplayBounds.size.height);

    CGSize mainScreenSize = ((CGRect (*)(id, SEL, int))objc_msgSend)(
        [UIScreen mainScreen],
        NSSelectorFromString(@"boundsForOrientation:"),
        desiredOrientation
    ).size;

    CGFloat widthScale = carplayDisplaySize.width / mainScreenSize.width;
    CGFloat heightScale = carplayDisplaySize.height / mainScreenSize.height;
    CGFloat xOrigin = [[self rootWindow] frame].origin.x;

    if (UIInterfaceOrientationIsPortrait((UIInterfaceOrientation)desiredOrientation))
    {
        widthScale = (carplayDisplaySize.width / 2) / mainScreenSize.width;
        CGFloat scaledDisplayWidth = carplayDisplaySize.width * widthScale;
        xOrigin = (carplayDisplaySize.width / 2) - (scaledDisplayWidth / 2);
    }

    [hostingContentView setTransform:CGAffineTransformMakeScale(widthScale, heightScale)];
    [[self.appViewController view] setFrame:CGRectMake(
        xOrigin,
        [[self.appViewController view] frame].origin.y,
        carplayDisplaySize.width,
        carplayDisplaySize.height
    )];

    UIView *containingView = [self appContainerView];
    CGRect containingViewFrame = [containingView frame];
    containingViewFrame.origin.x = (rightHandDock) ? 0 : dockWidth;
    containingViewFrame.size.width = carplayDisplaySize.width;
    containingViewFrame.size.height = carplayDisplaySize.height;
    [containingView setFrame:containingViewFrame];

    [self.dockView setAlpha:(fullscreen) ? 0 : 1];

    self.orientation = desiredOrientation;
    self.isFullscreen = fullscreen;
}

- (BOOL)shouldUseRightHandDock
{
    // Should the dock be drawn on the left or right side of the screen
    switch ([[CRPreferences sharedInstance] dockAlignment])
    {
        case CRDockAlignmentLeft:
            return NO;
        case CRDockAlignmentRight:
            return YES;
        case CRDockAlignmentAuto:
        {
            // Auto mode - determine which alignment Carplay is using and mimick it
            id carplaySession = objcInvoke(self.sessionStatus, @"session");
            id usesRightHand = objcInvoke_1(carplaySession, @"_endpointValueForKey:", @"RightHandDrive");
            return [usesRightHand boolValue];
        }
        default:
        {
            break;
        }
    }

    return NO;
}


- (void)layoutVisibleSplitApps
{
    if (!self.splitScreenEnabled || !self.appViewController2 || !self.appContainerView2) return;

    BOOL a = !self.appContainerView.hidden;
    BOOL b = !self.appContainerView2.hidden;

    if (!a && !b) {
        self.appContainerView.hidden = NO;
        a = YES;
    }

    CGRect r = self.rootWindow.bounds;
    CGFloat d = self.isFullscreen ? 0 : CARPLAY_DOCK_WIDTH;
    CGFloat x = [self shouldUseRightHandDock] ? 0 : d;
    CGFloat w = r.size.width - d;

    if (a && b) {
        CGFloat g = 2.0f;
        CGFloat ratio = (self.splitRatio > 0.15f && self.splitRatio < 0.85f) ? self.splitRatio : 0.5f;
        CGFloat l = (w - g) * ratio;
        self.appContainerView.frame = CGRectMake(x, 0, l, r.size.height);
        self.appContainerView2.frame = CGRectMake(x + l + g, 0, w - g - l, r.size.height);
    } else {
        UIView *v = a ? self.appContainerView : self.appContainerView2;
        v.frame = CGRectMake(x, 0, w, r.size.height);
    }
}

- (void)toggleFirstSplitApp
{
    if (!self.splitScreenEnabled || !self.appViewController2) return;

    self.appContainerView.hidden = !self.appContainerView.hidden;
    if (self.appContainerView.hidden && self.appContainerView2.hidden) {
        self.appContainerView2.hidden = NO;
    }
    [self layoutVisibleSplitApps];
}

- (void)toggleSecondSplitApp
{
    if (!self.splitScreenEnabled || !self.appViewController2) return;

    self.appContainerView2.hidden = !self.appContainerView2.hidden;
    if (self.appContainerView.hidden && self.appContainerView2.hidden) {
        self.appContainerView.hidden = NO;
    }
    [self layoutVisibleSplitApps];
}

- (void)toggleSplitRatio
{
    if (!self.splitScreenEnabled || !self.appViewController2) return;

    // Cycle through: 50/50 -> 70/30 (Maps major) -> 30/70 (Media major) -> 50/50
    if (self.splitRatio < 0.55f && self.splitRatio > 0.45f) {
        self.splitRatio = 0.70f;
    } else if (self.splitRatio > 0.65f) {
        self.splitRatio = 0.30f;
    } else {
        self.splitRatio = 0.50f;
    }

    UIButton *ratioBtn = (UIButton *)[self.dockView viewWithTag:9103];
    if (ratioBtn) {
        if (self.splitRatio > 0.65f) {
            [ratioBtn setTitle:@"7:3" forState:UIControlStateNormal];
            [ratioBtn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        } else if (self.splitRatio < 0.35f) {
            [ratioBtn setTitle:@"3:7" forState:UIControlStateNormal];
            [ratioBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
        } else {
            [ratioBtn setTitle:@"5:5" forState:UIControlStateNormal];
            [ratioBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
        }
    }
    [self layoutVisibleSplitApps];
}

- (void)selectAppForSplitWithBundleIdentifier:(NSString *)identifier
{
    BOOL keepSingleVisible = NO;

    if (self.splitScreenEnabled && self.appContainerView2) {
        // If App 1 is hidden while App 2 is full-screen, swap the logical slots
        if (self.appContainerView.hidden && !self.appContainerView2.hidden) {
            UIView *container = self.appContainerView;
            self.appContainerView = self.appContainerView2;
            self.appContainerView2 = container;

            id controller = self.appViewController;
            self.appViewController = self.appViewController2;
            self.appViewController2 = controller;

            id monitor = self.sceneMonitor;
            self.sceneMonitor = self.sceneMonitor2;
            self.sceneMonitor2 = monitor;

            id app = self.application;
            self.application = self.application2;
            self.application2 = app;
        }

        keepSingleVisible = (!self.appContainerView.hidden && self.appContainerView2.hidden);
    }

    [self setupSecondAppWithBundleIdentifier:identifier];

    if (keepSingleVisible && self.appContainerView2) {
        self.appContainerView.hidden = NO;
        self.appContainerView2.hidden = YES;
        [self layoutVisibleSplitApps];
    }
}

@end