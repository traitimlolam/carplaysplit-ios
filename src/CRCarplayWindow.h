#include <UIKit/UIKit.h>

id getCarplayCADisplay(void);

@interface CRCarPlayWindow : NSObject

@property (nonatomic, retain) UIWindow *rootWindow;
@property (nonatomic, retain) UIView *dockView;

// App 1
@property (nonatomic, retain) UIView *appContainerView;
@property (nonatomic, retain) id appViewController;
@property (nonatomic, retain) id sceneMonitor;
@property (nonatomic, retain) id application;

// App 2 (split-screen)
@property (nonatomic, retain) UIView *appContainerView2;
@property (nonatomic, retain) id appViewController2;
@property (nonatomic, retain) id sceneMonitor2;
@property (nonatomic, retain) id application2;

@property (nonatomic, retain) UIImageView *launchImageView;
@property (nonatomic, retain) UIView *fullscreenTransparentOverlay;
@property (nonatomic, retain) id sessionStatus;
@property (nonatomic, retain) NSMutableArray *observers;
@property (nonatomic, retain) UITapGestureRecognizer *screenTapRecognizer;

@property (nonatomic) int orientation;
@property (nonatomic) BOOL isFullscreen;
@property (nonatomic) BOOL shouldGenerateSnapshot;
@property (nonatomic) BOOL drawOnMainScreen;
@property (nonatomic) BOOL splitScreenEnabled;
@property (nonatomic) CGFloat splitRatio;

- (void)layoutVisibleSplitApps;
- (void)toggleFirstSplitApp;
- (void)toggleSecondSplitApp;
- (void)toggleSplitRatio;

- (id)initWithBundleIdentifier:(NSString *)identifier;

// Home: hide overlay but keep App 1 alive so another dashboard icon can be picked.
- (void)dismiss;

// X: fully close both hosted apps.
- (void)hardDismiss;

- (void)showCarPlayWindow;
- (void)setupSecondAppWithBundleIdentifier:(NSString *)identifier;

@end
