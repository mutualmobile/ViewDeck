//
//  IIViewDeckController.m
//  IIViewDeck
//
//  Copyright (C) 2011, Tom Adriaenssen
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of
//  this software and associated documentation files (the "Software"), to deal in
//  the Software without restriction, including without limitation the rights to
//  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
//  of the Software, and to permit persons to whom the Software is furnished to do
//  so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

// define some LLVM3 macros if the code is compiled with a different compiler (ie LLVMGCC42)
#ifndef __has_feature
#define __has_feature(x) 0
#endif
#ifndef __has_extension
#define __has_extension __has_feature // Compatibility with pre-3.0 compilers.
#endif

#define II_FLOAT_EQUAL(x, y) (((x) - (y)) == 0.0f)
#define II_STRING_EQUAL(a, b) ((a == nil && b == nil) || (a != nil && [a isEqualToString:b]))

#define II_CGRectOffsetRightAndShrink(rect, offset)         \
({                                                        \
__typeof__(rect) __r = (rect);                          \
__typeof__(offset) __o = (offset);                      \
(CGRect) {  { __r.origin.x, __r.origin.y },            \
{ __r.size.width - __o, __r.size.height }  \
};                                            \
})
#define II_CGRectOffsetTopAndShrink(rect, offset)           \
({                                                        \
__typeof__(rect) __r = (rect);                          \
__typeof__(offset) __o = (offset);                      \
(CGRect) { { __r.origin.x,   __r.origin.y    + __o },   \
{ __r.size.width, __r.size.height - __o }    \
};                                             \
})
#define II_CGRectOffsetBottomAndShrink(rect, offset)        \
({                                                        \
__typeof__(rect) __r = (rect);                          \
__typeof__(offset) __o = (offset);                      \
(CGRect) { { __r.origin.x, __r.origin.y },              \
{ __r.size.width, __r.size.height - __o}     \
};                                             \
})
#define II_CGRectShrink(rect, w, h)                             \
({                                                            \
__typeof__(rect) __r = (rect);                              \
__typeof__(w) __w = (w);                                    \
__typeof__(h) __h = (h);                                    \
(CGRect) {  __r.origin,                                     \
{ __r.size.width - __w, __r.size.height - __h}   \
};                                                 \
})

#import "IIViewDeckController.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "IIWrapController.h"

typedef NS_ENUM(NSInteger, IIViewDeckViewState){
    IIViewDeckViewStateHidden = 0,
    IIViewDeckViewStateInTransition,
    IIViewDeckViewStateVisible
};

CGFloat const kIIViewDeckDefaultDuration = 0.0f;
CGFloat const kIIViewDeckDefaultBounceDurationFactor = 0.25f;
CGFloat const kIIViewDeckDefaultOpenSlideAnimationDuration = 0.25f;
CGFloat const kIIViewDeckDefaultCloseSlideAnimationDuration = 0.3f;
CGFloat const kIIViewDeckDefaultLedgeWidth = 44.f;
UIViewAnimationOptions const kIIViewDeckDefaultSwipeAnimationCurve = UIViewAnimationOptionCurveEaseOut;
CGFloat const kIIViewDeckDefaultScootAnimationDuration = 0.5f;

typedef void(^IIViewDeckAppearanceBlock)(UIViewController* controller);

static inline BOOL IIViewDeckCanTapToClose(IIViewDeckCenterHiddenInteraction interactivity){
    return ((interactivity == IIViewDeckCenterHiddenInteractionTapToClose) ||
            (interactivity == IIViewDeckCenterHiddenInteractionTapToCloseBouncing));
}

static inline BOOL IIViewDeckIsInteractiveWhenOpen(IIViewDeckCenterHiddenInteraction interactivity){
    return (interactivity != IIViewDeckCenterHiddenInteractionNone);
}

inline NSString* NSStringFromIIViewDeckSide(IIViewDeckSide side) {
    switch (side) {
        case IIViewDeckSideLeft:
            return @"left";
            
        case IIViewDeckSideRight:
            return @"right";
            
        case IIViewDeckSideTop:
            return @"top";
            
        case IIViewDeckSideBottom:
            return @"bottom";
            
        case IIViewDeckSideNone:
            return @"no";
            
        default:
            return @"unknown";
    }
}

inline IIViewDeckOffsetOrientation IIViewDeckOffsetOrientationFromIIViewDeckSide(IIViewDeckSide side) {
    switch (side) {
        case IIViewDeckSideLeft:
        case IIViewDeckSideRight:
            return IIViewDeckOrientationHorizontal;
            
        case IIViewDeckSideTop:
        case IIViewDeckSideBottom:
            return IIViewDeckOrientationVertical;
            
        default:
            return IIViewDeckOrientationNone;
    }
}

static inline NSTimeInterval durationToAnimate(CGFloat pointsToAnimate, CGFloat velocity)
{
    NSTimeInterval animationDuration = pointsToAnimate / fabsf(velocity);
    // adjust duration for easing curve, if necessary
    if (kIIViewDeckDefaultSwipeAnimationCurve != UIViewAnimationOptionCurveLinear){
        animationDuration *= 1.25;
    }
    
    return animationDuration;
}

@interface IIViewDeckController () <UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIView* referenceView;
@property (nonatomic, readonly) CGRect referenceBounds;
@property (nonatomic, readonly) CGRect centerViewBounds;
@property (nonatomic, readonly) CGRect sideViewBounds;
@property (nonatomic, strong) NSMutableArray* panGestureRecognizers;
@property (nonatomic, strong) NSMutableArray* tapGestureRecognizers;
@property (nonatomic) CGFloat originalShadowRadius;
@property (nonatomic) CGFloat originalShadowOpacity;
@property (nonatomic, strong) UIColor* originalShadowColor;
@property (nonatomic) CGSize originalShadowOffset;
@property (nonatomic, strong) UIBezierPath* originalShadowPath;
@property (nonatomic, strong) UIView* centerTapperView;
@property (nonatomic, strong) UIView* centerView;
@property (nonatomic, weak, readonly) UIView* slidingControllerView;

- (void)cleanup;

- (CGRect)slidingRectForOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation;
- (CGSize)slidingSizeForOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation;
- (void)setSlidingFrameForOffset:(CGFloat)frame forOrientation:(IIViewDeckOffsetOrientation)orientation;
- (void)setSlidingFrameForOffset:(CGFloat)offset limit:(BOOL)limit forOrientation:(IIViewDeckOffsetOrientation)orientation;
- (void)setSlidingFrameForOffset:(CGFloat)offset limit:(BOOL)limit panning:(BOOL)panning forOrientation:(IIViewDeckOffsetOrientation)orientation;
- (void)panToSlidingFrameForOffset:(CGFloat)frame forOrientation:(IIViewDeckOffsetOrientation)orientation;
- (void)hideAppropriateSideViews;

- (BOOL)setSlidingAndReferenceViews;
- (void)applyShadowToSlidingViewAnimated:(BOOL)animated;
- (void)restoreShadowToSlidingView;
- (void)arrangeViewsAfterRotation;
- (CGFloat)relativeStatusBarHeight;

- (NSArray *)bouncingValuesForViewSide:(IIViewDeckSide)viewSide maximumBounce:(CGFloat)maxBounce numberOfBounces:(CGFloat)numberOfBounces dampingFactor:(CGFloat)zeta duration:(NSTimeInterval)duration;

- (void)centerViewVisible;
- (void)centerViewHidden;
- (void)centerTapped;

- (void)addPanGestureRecognizers;
- (void)addTapGestureRecognizers;
- (void)removePanGestureRecognizers;
- (void)removeTapGestureRecognizers;


- (BOOL)checkCanOpenSide:(IIViewDeckSide)viewDeckSide;
- (BOOL)checkCanCloseSide:(IIViewDeckSide)viewDeckSide;
- (void)notifyWillOpenSide:(IIViewDeckSide)viewDeckSide animated:(BOOL)animated;
- (void)notifyDidOpenSide:(IIViewDeckSide)viewDeckSide animated:(BOOL)animated;
- (void)notifyWillCloseSide:(IIViewDeckSide)viewDeckSide animated:(BOOL)animated;
- (void)notifyDidCloseSide:(IIViewDeckSide)viewDeckSide animated:(BOOL)animated;
- (void)notifyDidChangeOffset:(CGFloat)offset orientation:(IIViewDeckOffsetOrientation)orientation panning:(BOOL)panning;
- (void)notifyWillChangeOffset:(CGFloat)offset orientation:(IIViewDeckOffsetOrientation)orientation panning:(BOOL)panning;

- (BOOL)checkDelegate:(SEL)selector side:(IIViewDeckSide)viewDeckSize;
- (void)performDelegate:(SEL)selector side:(IIViewDeckSide)viewDeckSize animated:(BOOL)animated;
- (void)performDelegate:(SEL)selector side:(IIViewDeckSide)viewDeckSize controller:(UIViewController*)controller;
- (void)performDelegate:(SEL)selector offset:(CGFloat)offset orientation:(IIViewDeckOffsetOrientation)orientation panning:(BOOL)panning;

- (void)relayRotationMethod:(void(^)(UIViewController* controller))relay;

- (CGFloat)openSlideDuration:(BOOL)animated;
- (CGFloat)closeSlideDuration:(BOOL)animated;

@end


@interface UIViewController (UIViewDeckItem_Internal)

// internal setter for the viewDeckController property on UIViewController
- (void)setViewDeckController:(IIViewDeckController*)viewDeckController;

@end

@implementation IIViewDeckController

@dynamic leftController;
@dynamic rightController;
@dynamic topController;
@dynamic bottomController;

#pragma mark - Initalisation and deallocation

- (instancetype)init{
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController {
    if ((self = [super init])) {
        [self commonInit];
        
        self.centerController = centerController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController leftViewController:(UIViewController*)leftController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.leftController = leftController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController rightViewController:(UIViewController*)rightController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.rightController = rightController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController leftViewController:(UIViewController*)leftController rightViewController:(UIViewController*)rightController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.leftController = leftController;
        self.rightController = rightController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController topViewController:(UIViewController*)topController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.topController = topController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController bottomViewController:(UIViewController*)bottomController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.bottomController = bottomController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController topViewController:(UIViewController*)topController bottomViewController:(UIViewController*)bottomController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.topController = topController;
        self.bottomController = bottomController;
    }
    return self;
}

- (instancetype)initWithCenterViewController:(UIViewController*)centerController leftViewController:(UIViewController*)leftController rightViewController:(UIViewController*)rightController topViewController:(UIViewController*)topController bottomViewController:(UIViewController*)bottomController {
    if ((self = [self initWithCenterViewController:centerController])) {
        self.leftController = leftController;
        self.rightController = rightController;
        self.topController = topController;
        self.bottomController = bottomController;
    }
    return self;
}

- (void)commonInit{
    _elastic = YES;
    _willAppearShouldArrangeViewsAfterRotation = (UIInterfaceOrientation)UIDeviceOrientationUnknown;
    _panningMode = IIViewDeckPanningModeFullView;
    _navigationControllerBehavior = IIViewDeckNavigationControllerBehaviorContained;
    _centerhiddenInteractivity = IIViewDeckCenterHiddenInteractionFull;
    _sizeMode = IIViewDeckSizeModeLedge;
    self.panGestureRecognizers = [NSMutableArray array];
    self.tapGestureRecognizers = [NSMutableArray array];
    self.enabled = YES;
    _bounceDurationFactor = kIIViewDeckDefaultBounceDurationFactor;
    _openSlideAnimationDuration = kIIViewDeckDefaultOpenSlideAnimationDuration;
    _closeSlideAnimationDuration = kIIViewDeckDefaultCloseSlideAnimationDuration;
    _offsetOrientation = IIViewDeckOrientationHorizontal;
    
    _delegateMode = IIViewDeckDelegateModeDelegateOnly;
    
    _ledge[IIViewDeckSideLeft] = _ledge[IIViewDeckSideRight] = _ledge[IIViewDeckSideTop] = _ledge[IIViewDeckSideBottom] = kIIViewDeckDefaultLedgeWidth;
}

- (void)cleanup {
    self.originalShadowRadius = 0;
    self.originalShadowOpacity = 0;
    self.originalShadowColor = nil;
    self.originalShadowOffset = CGSizeZero;
    self.originalShadowPath = nil;
    
    _slidingController = nil;
    self.referenceView = nil;
    self.centerView = nil;
    self.centerTapperView = nil;
    self.tapGestureRecognizers = nil;
    self.panGestureRecognizers = nil;
}

- (void)dealloc {
    [self cleanup];
    
    self.centerController.viewDeckController = nil;
    self.leftController.viewDeckController = nil;
    self.leftController = nil;
    self.rightController.viewDeckController = nil;
    self.rightController = nil;
}

#pragma mark - Memory management

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    [self.centerController didReceiveMemoryWarning];
    [self.leftController didReceiveMemoryWarning];
    [self.rightController didReceiveMemoryWarning];
}

#pragma mark - Bookkeeping

- (NSArray*)controllers {
    NSMutableArray *result = [NSMutableArray array];
    if (self.centerController) [result addObject:self.centerController];
    if (self.leftController) [result addObject:self.leftController];
    if (self.rightController) [result addObject:self.rightController];
    if (self.topController) [result addObject:self.topController];
    if (self.bottomController) [result addObject:self.bottomController];
    return [NSArray arrayWithArray:result];
}

- (CGRect)referenceBounds {
    if (self.referenceView != nil){
        return self.referenceView.bounds;
    }
    else{
        return [[UIScreen mainScreen] bounds];
    }
}

- (CGFloat)relativeStatusBarHeight {
    if ([self.referenceView isKindOfClass:[UIWindow class]] == NO){
        return 0;
    }
    
    return [self statusBarHeight];
}

- (CGFloat)statusBarHeight {
    if(UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation)){
        return [UIApplication sharedApplication].statusBarFrame.size.width;
    }
    else{
        return [UIApplication sharedApplication].statusBarFrame.size.height;
    }
}

- (CGRect)centerViewBounds {
    if (self.navigationControllerBehavior == IIViewDeckNavigationControllerBehaviorContained){
        return self.referenceBounds;
    }
    
    CGFloat height = 0.f;
    if(self.navigationController.navigationBarHidden == NO){
        height = self.navigationController.navigationBar.frame.size.height;
    }
    return II_CGRectShrink(self.referenceBounds,
                           0,
                           [self relativeStatusBarHeight] + height);
}

- (CGRect)sideViewBounds {
    if (self.navigationControllerBehavior == IIViewDeckNavigationControllerBehaviorContained){
        return self.referenceBounds;
    }
    
    return II_CGRectOffsetTopAndShrink(self.referenceBounds,
                                       [self relativeStatusBarHeight]);
}

- (CGFloat)limitOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation {
    if (orientation == IIViewDeckOrientationHorizontal) {
        if ((self.leftController != nil) &&
            (self.rightController != nil)){
            return offset;
        }
        
        if ((self.leftController != nil) &&
            (_maxLedge > 0)) {
            CGFloat left = self.referenceBounds.size.width - _maxLedge;
            offset = MIN(offset, left);
        }
        else if ((self.rightController != nil) &&
                 (_maxLedge > 0)) {
            CGFloat right = _maxLedge - self.referenceBounds.size.width;
            offset = MAX(offset, right);
        }
        
        return offset;
    }
    else {
        if ((self.topController != nil) &&
            (self.bottomController != nil)) {
            return offset;
        }
        
        if ((self.topController != nil) &&
            (_maxLedge > 0)) {
            CGFloat top = self.referenceBounds.size.height - _maxLedge;
            offset = MIN(offset, top);
        }
        else if ((self.bottomController != nil) &&
                 (_maxLedge > 0)) {
            CGFloat bottom = _maxLedge - self.referenceBounds.size.height;
            offset = MAX(offset, bottom);
        }
        
        return offset;
    }
    
}

- (CGRect)slidingRectForOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation {
    offset = [self limitOffset:offset forOrientation:orientation];
    
    CGRect slidingRect;
    if (orientation == IIViewDeckOrientationHorizontal) {
        slidingRect.origin = (CGPoint){self.resizesCenterView && offset < 0 ? 0 : offset, 0};
        slidingRect.size = [self slidingSizeForOffset:offset forOrientation:orientation];
    }
    else {
        slidingRect.origin = (CGPoint){0, self.resizesCenterView && offset < 0 ? 0 : offset};
        slidingRect.size = [self slidingSizeForOffset:offset forOrientation:orientation];
    }
    
    return slidingRect;
}

- (CGSize)slidingSizeForOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation {
    if (!self.resizesCenterView) return self.referenceBounds.size;
    
    offset = [self limitOffset:offset forOrientation:orientation];
    if (orientation == IIViewDeckOrientationHorizontal) {
        return CGSizeMake(self.centerViewBounds.size.width - ABS(offset),
                          self.centerViewBounds.size.height );
    }
    else {
        return CGSizeMake(self.centerViewBounds.size.width,
                          self.centerViewBounds.size.height - ABS(offset));
    }
}

-(void)setSlidingFrameForOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation {
    [self setSlidingFrameForOffset:offset limit:YES panning:NO forOrientation:orientation];
}

-(void)panToSlidingFrameForOffset:(CGFloat)offset forOrientation:(IIViewDeckOffsetOrientation)orientation {
    [self setSlidingFrameForOffset:offset limit:YES panning:YES forOrientation:orientation];
}

-(void)setSlidingFrameForOffset:(CGFloat)offset limit:(BOOL)limit forOrientation:(IIViewDeckOffsetOrientation)orientation {
    [self setSlidingFrameForOffset:offset limit:limit panning:NO forOrientation:orientation];
}

-(void)setSlidingFrameForOffset:(CGFloat)offset limit:(BOOL)limit panning:(BOOL)panning forOrientation:(IIViewDeckOffsetOrientation)orientation {
    CGFloat beforeOffset = _offset;
    if (limit)
        offset = [self limitOffset:offset forOrientation:orientation];
    _offset = offset;
    _offsetOrientation = orientation;
    self.slidingControllerView.frame = [self slidingRectForOffset:_offset forOrientation:orientation];
    if (beforeOffset != _offset)
        [self notifyDidChangeOffset:_offset orientation:orientation panning:panning];
}

- (void)hideAppropriateSideViews {
    self.leftController.view.hidden = CGRectGetMinX(self.slidingControllerView.frame) <= 0;
    self.rightController.view.hidden = CGRectGetMaxX(self.slidingControllerView.frame) >= self.referenceBounds.size.width;
    self.topController.view.hidden = CGRectGetMinY(self.slidingControllerView.frame) <= 0;
    self.bottomController.view.hidden = CGRectGetMaxY(self.slidingControllerView.frame) >= self.referenceBounds.size.height;
}

#pragma mark - Ledges

- (void)setSize:(CGFloat)size forSide:(IIViewDeckSide)side completion:(void(^)(BOOL finished))completion {
    // we store ledge sizes internally but allow size to be specified depending on size mode.
    CGFloat ledge = [self sizeAsLedge:size forSide:side];
    
    CGFloat minLedge;
    CGFloat(^offsetter)(CGFloat ledge);
    
    switch (side) {
        case IIViewDeckSideLeft: {
            minLedge = MIN(self.referenceBounds.size.width, ledge);
            offsetter = ^CGFloat(CGFloat l) { return  self.referenceBounds.size.width - l; };
            break;
        }
            
        case IIViewDeckSideRight: {
            minLedge = MIN(self.referenceBounds.size.width, ledge);
            offsetter = ^CGFloat(CGFloat l) { return l - self.referenceBounds.size.width; };
            break;
        }
            
        case IIViewDeckSideTop: {
            minLedge = MIN(self.referenceBounds.size.width, ledge);
            offsetter = ^CGFloat(CGFloat l) { return  self.referenceBounds.size.height - l; };
            break;
        }
            
        case IIViewDeckSideBottom: {
            minLedge = MIN(self.referenceBounds.size.width, ledge);
            offsetter = ^CGFloat(CGFloat l) { return l - self.referenceBounds.size.height; };
            break;
        }
            
        default:
            return;
    }
    
    ledge = MAX(ledge, minLedge);
    if (_viewFirstAppeared && II_FLOAT_EQUAL(self.slidingControllerView.frame.origin.x, offsetter(_ledge[side]))) {
        IIViewDeckOffsetOrientation orientation = IIViewDeckOffsetOrientationFromIIViewDeckSide(side);
        if (ledge < _ledge[side]) {
            [UIView animateWithDuration:[self closeSlideDuration:YES] animations:^{
                [self setSlidingFrameForOffset:offsetter(ledge) forOrientation:orientation];
            } completion:completion];
        }
        else if (ledge > _ledge[side]) {
            [UIView animateWithDuration:[self openSlideDuration:YES] animations:^{
                [self setSlidingFrameForOffset:offsetter(ledge) forOrientation:orientation];
            } completion:completion];
        }
    }
    
    [self setLedgeValue:ledge forSide:side];
}

- (CGFloat)sizeForSide:(IIViewDeckSide)side {
    return [self ledgeAsSize:_ledge[side] forSide:side];
}

#pragma mark Left size

- (void)setLeftSize:(CGFloat)leftSize {
    [self setLeftSize:leftSize completion:nil];
}

- (void)setLeftSize:(CGFloat)leftSize completion:(void(^)(BOOL finished))completion {
    [self setSize:leftSize forSide:IIViewDeckSideLeft completion:completion];
}

- (CGFloat)leftSize {
    return [self sizeForSide:IIViewDeckSideLeft];
}

- (CGFloat)leftViewSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideLeft] mode:IIViewDeckSizeModeView forSide:IIViewDeckSideLeft];
}

- (CGFloat)leftLedgeSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideLeft] mode:IIViewDeckSizeModeLedge forSide:IIViewDeckSideLeft];
}

#pragma mark Right size

- (void)setRightSize:(CGFloat)rightSize {
    [self setRightSize:rightSize completion:nil];
}

- (void)setRightSize:(CGFloat)rightSize completion:(void(^)(BOOL finished))completion {
    [self setSize:rightSize forSide:IIViewDeckSideRight completion:completion];
}

- (CGFloat)rightSize {
    return [self sizeForSide:IIViewDeckSideRight];
}

- (CGFloat)rightViewSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideRight] mode:IIViewDeckSizeModeView forSide:IIViewDeckSideRight];
}

- (CGFloat)rightLedgeSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideRight] mode:IIViewDeckSizeModeLedge forSide:IIViewDeckSideRight];
}


#pragma mark Top size

- (void)setTopSize:(CGFloat)leftSize {
    [self setTopSize:leftSize completion:nil];
}

- (void)setTopSize:(CGFloat)topSize completion:(void(^)(BOOL finished))completion {
    [self setSize:topSize forSide:IIViewDeckSideTop completion:completion];
}

- (CGFloat)topSize {
    return [self sizeForSide:IIViewDeckSideTop];
}

- (CGFloat)topViewSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideTop] mode:IIViewDeckSizeModeView forSide:IIViewDeckSideTop];
}

- (CGFloat)topLedgeSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideTop] mode:IIViewDeckSizeModeLedge forSide:IIViewDeckSideTop];
}


#pragma mark Bottom size

- (void)setBottomSize:(CGFloat)bottomSize {
    [self setBottomSize:bottomSize completion:nil];
}

- (void)setBottomSize:(CGFloat)bottomSize completion:(void(^)(BOOL finished))completion {
    [self setSize:bottomSize forSide:IIViewDeckSideBottom completion:completion];
}

- (CGFloat)bottomSize {
    return [self sizeForSide:IIViewDeckSideBottom];
}

- (CGFloat)bottomViewSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideBottom] mode:IIViewDeckSizeModeView forSide:IIViewDeckSideBottom];
}

- (CGFloat)bottomLedgeSize {
    return [self ledgeAsSize:_ledge[IIViewDeckSideBottom] mode:IIViewDeckSizeModeLedge forSide:IIViewDeckSideBottom];
}


#pragma mark Max size

- (void)setMaxSize:(CGFloat)maxSize {
    [self setMaxSize:maxSize completion:nil];
}

- (void)setMaxSize:(CGFloat)maxSize completion:(void(^)(BOOL finished))completion {
    int count = (self.leftController ? 1 : 0) + (self.rightController ? 1 : 0) + (self.topController ? 1 : 0) + (self.bottomController ? 1 : 0);
    
    if (count > 1) {
        NSLog(@"IIViewDeckController: warning: setting maxLedge with more than one side controllers. Value will be ignored.");
        return;
    }
    
    [self executeBlockOnSideControllers:^(UIViewController* controller, IIViewDeckSide side) {
        if (controller) {
            _maxLedge = [self sizeAsLedge:maxSize forSide:side];
            if (_ledge[side] > _maxLedge)
                [self setSize:maxSize forSide:side completion:completion];
            [self setSlidingFrameForOffset:_offset forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(side)]; // should be animated
        }
    }];
}

- (CGFloat)maxSize {
    return _maxLedge;
}

- (CGFloat)sizeAsLedge:(CGFloat)size forSide:(IIViewDeckSide)side {
    if (_sizeMode == IIViewDeckSizeModeLedge)
        return size;
    else {
        return ((side == IIViewDeckSideLeft || side == IIViewDeckSideRight)
                ? self.referenceBounds.size.width : self.referenceBounds.size.height) - size;
    }
}

- (CGFloat)ledgeAsSize:(CGFloat)ledge forSide:(IIViewDeckSide)side {
    return [self ledgeAsSize:ledge mode:_sizeMode forSide:side];
}

- (CGFloat)ledgeAsSize:(CGFloat)ledge mode:(IIViewDeckSizeMode)mode forSide:(IIViewDeckSide)side {
    if (mode == IIViewDeckSizeModeLedge)
        return ledge;
    else
        return ((side == IIViewDeckSideLeft || side == IIViewDeckSideRight)
                ? self.referenceBounds.size.width : self.referenceBounds.size.height) - ledge;
}

#pragma mark - View Lifecycle

- (void)loadView
{
    _offset = 0;
    _viewFirstAppeared = NO;
    _viewAppeared = 0;
    self.view = [[UIView alloc] init];
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view.autoresizesSubviews = YES;
    self.view.clipsToBounds = YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.centerView = [[UIView alloc] init];
    self.centerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.centerView.autoresizesSubviews = YES;
    self.centerView.clipsToBounds = YES;
    [self.view addSubview:self.centerView];
    
    self.originalShadowRadius = 0;
    self.originalShadowOpacity = 0;
    self.originalShadowColor = nil;
    self.originalShadowOffset = CGSizeZero;
    self.originalShadowPath = nil;
}

- (void)viewDidUnload
{
    [self cleanup];
    [super viewDidUnload];
}

#pragma mark - View Containment


- (BOOL)shouldAutomaticallyForwardRotationMethods {
    return NO;
}

- (BOOL)shouldAutomaticallyForwardAppearanceMethods {
    return NO;
}

- (BOOL)automaticallyForwardAppearanceAndRotationMethodsToChildViewControllers {
    return NO;
}

#pragma mark - Appearance

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self.view addObserver:self forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:nil];
    
    if (!_viewFirstAppeared) {
        _viewFirstAppeared = YES;
        
        void(^applyViews)(void) = ^{
            [self.centerController.view removeFromSuperview];
            [self.centerView addSubview:self.centerController.view];
            
            [self executeBlockOnSideControllers:^(UIViewController* controller, IIViewDeckSide side) {
                [controller.view removeFromSuperview];
                [self.referenceView insertSubview:controller.view belowSubview:self.slidingControllerView];
            }];
            
            [self setSlidingFrameForOffset:_offset forOrientation:_offsetOrientation];
            self.slidingControllerView.hidden = NO;
            
            self.centerView.frame = self.centerViewBounds;
            self.centerController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.centerController.view.frame = self.centerView.bounds;
            [self executeBlockOnSideControllers:^(UIViewController* controller, IIViewDeckSide side) {
                controller.view.frame = self.sideViewBounds;
                controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            }];
            
            [self applyShadowToSlidingViewAnimated:NO];
        };
        
        if ([self setSlidingAndReferenceViews]) {
            applyViews();
            applyViews = nil;
        }
        
        // after 0.01 sec, since in certain cases the sliding view is reset.
        double delayInSeconds = 0.001;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            if (applyViews) applyViews();
            [self setSlidingFrameForOffset:_offset forOrientation:_offsetOrientation];
            [self hideAppropriateSideViews];
        });
        
        [self addPanGestureRecognizers];
        
        if ([self isSideClosed:IIViewDeckSideLeft] &&
            [self isSideClosed:IIViewDeckSideRight] &&
            [self isSideClosed:IIViewDeckSideTop] &&
            [self isSideClosed:IIViewDeckSideBottom])
            [self centerViewVisible];
        else
            [self centerViewHidden];
    }
    else if (_willAppearShouldArrangeViewsAfterRotation != UIDeviceOrientationUnknown) {
        for (NSString* key in [self.view.layer animationKeys]) {
            NSLog(@"%@ %f", [self.view.layer animationForKey:key], [self.view.layer animationForKey:key].duration);
        }
        
        [self willRotateToInterfaceOrientation:self.interfaceOrientation duration:0];
        [self willAnimateRotationToInterfaceOrientation:self.interfaceOrientation duration:0];
        [self didRotateFromInterfaceOrientation:_willAppearShouldArrangeViewsAfterRotation];
    }
    
    [self.centerController viewWillAppear:animated];
    [self transitionAppearanceFrom:IIViewDeckViewStateHidden
                                to:IIViewDeckViewStateInTransition
                          animated:animated];
    _viewAppeared = IIViewDeckViewStateInTransition;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    [self.centerController viewDidAppear:animated];
    [self transitionAppearanceFrom:IIViewDeckViewStateInTransition
                                to:IIViewDeckViewStateVisible
                          animated:animated];
    _viewAppeared = IIViewDeckViewStateVisible;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [self.centerController viewWillDisappear:animated];
    [self transitionAppearanceFrom:IIViewDeckViewStateVisible
                                to:IIViewDeckViewStateInTransition
                          animated:animated];
    _viewAppeared = IIViewDeckViewStateInTransition;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    @try {
        [self.view removeObserver:self forKeyPath:@"bounds"];
    } @catch(id anException){
        //do nothing, obviously it wasn't attached because an exception was thrown
    }
    
    [self.centerController viewDidDisappear:animated];
    [self transitionAppearanceFrom:IIViewDeckViewStateInTransition
                                to:IIViewDeckViewStateHidden
                          animated:animated];
    _viewAppeared = IIViewDeckViewStateHidden;
}

#pragma mark - Rotation IOS6

- (BOOL)shouldAutorotate {
    _preRotationSize = self.referenceBounds.size;
    _preRotationCenterSize = self.centerView.bounds.size;
    _willAppearShouldArrangeViewsAfterRotation = self.interfaceOrientation;
    
    // give other controllers a chance to act on it too
    [self relayRotationMethod:^(UIViewController *controller) {
        [controller shouldAutorotate];
    }];
    
    return !self.centerController || [self.centerController shouldAutorotate];
}

- (NSUInteger)supportedInterfaceOrientations {
    if (self.centerController)
        return [self.centerController supportedInterfaceOrientations];
    
    return [super supportedInterfaceOrientations];
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    if (self.centerController)
        return [self.centerController preferredInterfaceOrientationForPresentation];
    
    return [super preferredInterfaceOrientationForPresentation];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    _preRotationSize = self.referenceBounds.size;
    _preRotationCenterSize = self.centerView.bounds.size;
    _preRotationIsLandscape = UIInterfaceOrientationIsLandscape([UIApplication sharedApplication].statusBarOrientation);
    _willAppearShouldArrangeViewsAfterRotation = interfaceOrientation;
    
    // give other controllers a chance to act on it too
    [self relayRotationMethod:^(UIViewController *controller) {
        [controller shouldAutorotateToInterfaceOrientation:interfaceOrientation];
    }];
    
    return !self.centerController || [self.centerController shouldAutorotateToInterfaceOrientation:interfaceOrientation];
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    [super willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self arrangeViewsAfterRotation];
    
    [self relayRotationMethod:^(UIViewController *controller) {
        [controller willAnimateRotationToInterfaceOrientation:toInterfaceOrientation duration:duration];
    }];
}


- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self restoreShadowToSlidingView];
    
    if (_preRotationSize.width == 0) {
        _preRotationSize = self.referenceBounds.size;
        _preRotationCenterSize = self.centerView.bounds.size;
        _preRotationIsLandscape = UIInterfaceOrientationIsLandscape(self.interfaceOrientation);
    }
    
    [self relayRotationMethod:^(UIViewController *controller) {
        [controller willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    }];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    [self applyShadowToSlidingViewAnimated:YES];
    
    [self relayRotationMethod:^(UIViewController *controller) {
        [controller didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    }];
}

- (void)arrangeViewsAfterRotation {
    //This is fine to cast here since UIInterfaceOrientation begins enumerating at 1
    //  and UIDeviceOrientationUnknown is 0
    _willAppearShouldArrangeViewsAfterRotation = (UIInterfaceOrientation)UIDeviceOrientationUnknown;
    if (_preRotationSize.width <= 0 || _preRotationSize.height <= 0) return;
    
    CGFloat offset, max, preSize;
    IIViewDeckSide adjustOffset = IIViewDeckSideNone;
    if (_offsetOrientation == IIViewDeckOrientationVertical) {
        offset = self.slidingControllerView.frame.origin.y;
        max = self.referenceBounds.size.height;
        preSize = _preRotationSize.height;
        if (self.resizesCenterView && II_FLOAT_EQUAL(offset, 0)) {
            offset = offset + (_preRotationCenterSize.height - _preRotationSize.height);
        }
        if (!II_FLOAT_EQUAL(offset, 0)) {
            if (II_FLOAT_EQUAL(offset, preSize - _ledge[IIViewDeckSideTop]))
                adjustOffset = IIViewDeckSideTop;
            else if (II_FLOAT_EQUAL(offset, _ledge[IIViewDeckSideBottom] - preSize))
                adjustOffset = IIViewDeckSideBottom;
        }
    }
    else {
        offset = self.slidingControllerView.frame.origin.x;
        max = self.referenceBounds.size.width;
        preSize = _preRotationSize.width;
        if (self.resizesCenterView && II_FLOAT_EQUAL(offset, 0)) {
            offset = offset + (_preRotationCenterSize.width - _preRotationSize.width);
        }
        if (!II_FLOAT_EQUAL(offset, 0)) {
            if (II_FLOAT_EQUAL(offset, preSize - _ledge[IIViewDeckSideLeft]))
                adjustOffset = IIViewDeckSideLeft;
            else if (II_FLOAT_EQUAL(offset, _ledge[IIViewDeckSideRight] - preSize))
                adjustOffset = IIViewDeckSideRight;
        }
    }
    
    if (self.sizeMode != IIViewDeckSizeModeLedge) {
        if (_maxLedge != 0)
            _maxLedge = _maxLedge + max - preSize;
        
        [self setLedgeValue:_ledge[IIViewDeckSideLeft] + self.referenceBounds.size.width - _preRotationSize.width forSide:IIViewDeckSideLeft];
        [self setLedgeValue:_ledge[IIViewDeckSideRight] + self.referenceBounds.size.width - _preRotationSize.width forSide:IIViewDeckSideRight];
        [self setLedgeValue:_ledge[IIViewDeckSideTop] + self.referenceBounds.size.height - _preRotationSize.height forSide:IIViewDeckSideTop];
        [self setLedgeValue:_ledge[IIViewDeckSideBottom] + self.referenceBounds.size.height - _preRotationSize.height forSide:IIViewDeckSideBottom];
    }
    else {
        if (offset > 0) {
            offset = max - preSize + offset;
        }
        else if (offset < 0) {
            offset = offset + preSize - max;
        }
    }
    
    switch (adjustOffset) {
        case IIViewDeckSideLeft:
            offset = self.referenceBounds.size.width - _ledge[adjustOffset];
            break;
            
        case IIViewDeckSideRight:
            offset = _ledge[adjustOffset] - self.referenceBounds.size.width;
            break;
            
        case IIViewDeckSideTop:
            offset = self.referenceBounds.size.height - _ledge[adjustOffset];
            break;
            
        case IIViewDeckSideBottom:
            offset = _ledge[adjustOffset] - self.referenceBounds.size.height;
            break;
            
        default:
            break;
    }
    [self setSlidingFrameForOffset:offset forOrientation:_offsetOrientation];
    
    _preRotationSize = CGSizeZero;
}

- (void)setLedgeValue:(CGFloat)ledge forSide:(IIViewDeckSide)side {
    if (_maxLedge > 0)
        ledge = MIN(_maxLedge, ledge);
    
    _ledge[side] = [self performDelegate:@selector(viewDeckController:changesLedge:forSide:) ledge:ledge side:side];
}

#pragma mark - Notify

- (CGFloat)ledgeOffsetForSide:(IIViewDeckSide)viewDeckSide {
    NSAssert(viewDeckSide != IIViewDeckSideNone, @"Cannot have ledge offset for no side");
    NSAssert(viewDeckSide != IIViewDeckSideCenter, @"Cannot have ledge offset for center");
    
    switch (viewDeckSide) {
        case IIViewDeckSideLeft:
            return self.referenceBounds.size.width - _ledge[viewDeckSide];
        case IIViewDeckSideRight:
            return _ledge[viewDeckSide] - self.referenceBounds.size.width;
        case IIViewDeckSideTop:
            return self.referenceBounds.size.height - _ledge[viewDeckSide];
        case IIViewDeckSideBottom:
            return _ledge[viewDeckSide] - self.referenceBounds.size.height;
        default:
            return 0.f;
    }
}

- (void)executeBlockOnSideControllers:(void(^)(UIViewController* controller, IIViewDeckSide side))action {
    if (!action) return;
    for (IIViewDeckSide side=IIViewDeckSideLeft; side<=IIViewDeckSideBottom; side++) {
        action(_controllers[side], side);
    }
}

- (UIViewController*)controllerForSide:(IIViewDeckSide)viewDeckSide {
    return viewDeckSide == IIViewDeckSideNone ? nil : _controllers[viewDeckSide];
}

- (IIViewDeckSide)oppositeOfSide:(IIViewDeckSide)viewDeckSide {
    switch (viewDeckSide) {
        case IIViewDeckSideLeft:
            return IIViewDeckSideRight;
        case IIViewDeckSideRight:
            return IIViewDeckSideLeft;
        case IIViewDeckSideTop:
            return IIViewDeckSideBottom;
        case IIViewDeckSideBottom:
            return IIViewDeckSideTop;
        default:
            return IIViewDeckSideNone;
    }
}

- (IIViewDeckSide)sideForController:(UIViewController*)controller {
    for (IIViewDeckSide side=IIViewDeckSideLeft; side<=IIViewDeckSideBottom; side++) {
        if (_controllers[side] == controller) return side;
    }
    
    return NSNotFound;
}

- (BOOL)checkCanOpenSide:(IIViewDeckSide)viewDeckSide {
    return (![self isSideOpen:viewDeckSide] &&
            [self checkDelegate:@selector(viewDeckController:shouldOpenViewSide:) side:viewDeckSide]);
}

- (BOOL)checkCanCloseSide:(IIViewDeckSide)viewDeckSide {
    return (![self isSideClosed:viewDeckSide] &&
            [self checkDelegate:@selector(viewDeckController:shouldCloseViewSide:) side:viewDeckSide]);
}

- (void)notifyWillOpenSide:(IIViewDeckSide)viewDeckSide
                  animated:(BOOL)animated {
    if (viewDeckSide == IIViewDeckSideNone) return;
    
    [self notifyAppearanceForSide:viewDeckSide
                         animated:animated
                             from:IIViewDeckViewStateHidden
                               to:IIViewDeckViewStateInTransition];
    
    if ([self isSideClosed:viewDeckSide]) {
        [self performDelegate:@selector(viewDeckController:willOpenViewSide:animated:)
                         side:viewDeckSide
                     animated:animated];
    }
}

- (void)notifyDidOpenSide:(IIViewDeckSide)viewDeckSide
                 animated:(BOOL)animated {
    if (viewDeckSide == IIViewDeckSideNone) return;
    
    [self notifyAppearanceForSide:viewDeckSide
                         animated:animated
                             from:IIViewDeckViewStateInTransition
                               to:IIViewDeckViewStateVisible];
    
    if ([self isSideOpen:viewDeckSide]) {
        [self performDelegate:@selector(viewDeckController:didOpenViewSide:animated:)
                         side:viewDeckSide
                     animated:animated];
    }
}

- (void)notifyWillCloseSide:(IIViewDeckSide)viewDeckSide
                   animated:(BOOL)animated {
    if (viewDeckSide == IIViewDeckSideNone) return;
    
    [self notifyAppearanceForSide:viewDeckSide
                         animated:animated
                             from:IIViewDeckViewStateVisible
                               to:IIViewDeckViewStateInTransition];
    
    if (![self isSideClosed:viewDeckSide]) {
        [self performDelegate:@selector(viewDeckController:willCloseViewSide:animated:)
                         side:viewDeckSide
                     animated:animated];
    }
}

- (void)notifyClosingAnimationSide:(IIViewDeckSide)viewDeckSide
                          animated:(BOOL)animated {
    if (viewDeckSide == IIViewDeckSideNone) return;

    [self notifyAppearanceForSide:viewDeckSide
                         animated:animated
                             from:IIViewDeckViewStateVisible
                               to:IIViewDeckViewStateInTransition];

    if (![self isSideClosed:viewDeckSide]) {
        [self performDelegate:@selector(viewDeckController:closingAnimationViewSide:animated:)
                         side:viewDeckSide
                     animated:animated];
    }
}

- (void)notifyDidCloseSide:(IIViewDeckSide)viewDeckSide
                  animated:(BOOL)animated {
    if (viewDeckSide == IIViewDeckSideNone) return;
    
    [self notifyAppearanceForSide:viewDeckSide
                         animated:animated
                             from:IIViewDeckViewStateInTransition
                               to:IIViewDeckViewStateHidden];
    
    if ([self isSideClosed:viewDeckSide]) {
        [self performDelegate:@selector(viewDeckController:didCloseViewSide:animated:)
                         side:viewDeckSide
                     animated:animated];
        [self performDelegate:@selector(viewDeckController:didShowCenterViewFromSide:animated:)
                         side:viewDeckSide
                     animated:animated];
    }
}

- (void)notifyDidChangeOffset:(CGFloat)offset
                  orientation:(IIViewDeckOffsetOrientation)orientation
                      panning:(BOOL)panning {
    [self performDelegate:@selector(viewDeckController:didChangeOffset:orientation:panning:)
                   offset:offset
              orientation:orientation
                  panning:panning];
}

- (void)notifyWillChangeOffset:(CGFloat)offset
                   orientation:(IIViewDeckOffsetOrientation)orientation
                       panning:(BOOL)panning {
    [self performDelegate:@selector(viewDeckController:willChangeOffset:orientation:panning:)
                   offset:offset
              orientation:orientation
                  panning:panning];
}

- (void)notifyAppearanceForSide:(IIViewDeckSide)viewDeckSide
                       animated:(BOOL)animated
                           from:(IIViewDeckViewState)from
                             to:(IIViewDeckViewState)to {
    if (viewDeckSide == IIViewDeckSideNone)
        return;
    
    if (_viewAppeared < to) {
        _sideAppeared[viewDeckSide] = to;
        return;
    }
    
    SEL selector = nil;
    if (from < to) {
        if (_sideAppeared[viewDeckSide] > from){
            return;
        }
        
        if (to == IIViewDeckViewStateInTransition){
            selector = @selector(viewWillAppear:);
        }
        else if (to == IIViewDeckViewStateVisible){
            selector = @selector(viewDidAppear:);
        }
    }
    else {
        if (_sideAppeared[viewDeckSide] < from)
            return;
        
        if (to == 1){
            selector = @selector(viewWillDisappear:);
        }
        else if (to == 0){
            selector = @selector(viewDidDisappear:);
        }
    }
    
    _sideAppeared[viewDeckSide] = to;
    
    if (selector) {
        UIViewController* controller = [self controllerForSide:viewDeckSide];
        BOOL (*objc_msgSendTyped)(id self, SEL _cmd, BOOL animated) = (void*)objc_msgSend;
        objc_msgSendTyped(controller, selector, animated);
    }
}

- (void)transitionAppearanceFrom:(IIViewDeckViewState)from
                              to:(IIViewDeckViewState)to
                        animated:(BOOL)animated {
    SEL selector = nil;
    if (from < to) {
        if (to == IIViewDeckViewStateInTransition){
            selector = @selector(viewWillAppear:);
        }
        else if (to == IIViewDeckViewStateVisible){
            selector = @selector(viewDidAppear:);
        }
    }
    else {
        if (to == IIViewDeckViewStateInTransition){
            selector = @selector(viewWillDisappear:);
        }
        else if (to == IIViewDeckViewStateHidden){
            selector = @selector(viewDidDisappear:);
        }
    }
    
    [self executeBlockOnSideControllers:^(UIViewController *controller, IIViewDeckSide side) {
        if (from < to && _sideAppeared[side] <= from){
            return;
        }
        else if (from > to && _sideAppeared[side] >= from){
            return;
        }
        
        if (selector && controller) {
            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, BOOL animated) = (void*)objc_msgSend;
            objc_msgSendTyped(controller, selector, animated);
        }
    }];
}



#pragma mark - Controller State

-(void)setCenterhiddenInteractivity:(IIViewDeckCenterHiddenInteraction)centerhiddenInteractivity {
    _centerhiddenInteractivity = centerhiddenInteractivity;
    
    if ([self isAnySideOpen]) {
        if (IIViewDeckIsInteractiveWhenOpen(self.centerhiddenInteractivity)) {
            [self centerViewVisible];
        } else {
            [self centerViewHidden];
        }
    }
}

- (BOOL)isSideClosed:(IIViewDeckSide)viewDeckSide {
    if (![self controllerForSide:viewDeckSide]){
        return YES;
    }
    
    switch (viewDeckSide) {
        case IIViewDeckSideLeft:
            return CGRectGetMinX(self.slidingControllerView.frame) <= 0;
            
        case IIViewDeckSideRight:
            return CGRectGetMaxX(self.slidingControllerView.frame) >= self.referenceBounds.size.width;
            
        case IIViewDeckSideTop:
            return CGRectGetMinY(self.slidingControllerView.frame) <= 0;
            
        case IIViewDeckSideBottom:
            return CGRectGetMaxY(self.slidingControllerView.frame) >= self.referenceBounds.size.height;
            
        default:
            return YES;
    }
}


- (BOOL)isAnySideOpen {
    return ([self isSideOpen:IIViewDeckSideLeft] ||
            [self isSideOpen:IIViewDeckSideRight] ||
            [self isSideOpen:IIViewDeckSideTop] ||
            [self isSideOpen:IIViewDeckSideBottom]);
}


- (BOOL)isSideOpen:(IIViewDeckSide)viewDeckSide {
    if (![self controllerForSide:viewDeckSide]){
        return NO;
    }
    
    switch (viewDeckSide) {
        case IIViewDeckSideLeft:
            return II_FLOAT_EQUAL(CGRectGetMinX(self.slidingControllerView.frame), self.referenceBounds.size.width - _ledge[IIViewDeckSideLeft]);
            
        case IIViewDeckSideRight:
            return II_FLOAT_EQUAL(CGRectGetMaxX(self.slidingControllerView.frame), _ledge[IIViewDeckSideRight]);
            
        case IIViewDeckSideTop:
            return II_FLOAT_EQUAL(CGRectGetMinY(self.slidingControllerView.frame), self.referenceBounds.size.height - _ledge[IIViewDeckSideTop]);
            
        case IIViewDeckSideBottom:
            return II_FLOAT_EQUAL(CGRectGetMaxY(self.slidingControllerView.frame), _ledge[IIViewDeckSideBottom]);
            
        default:
            return NO;
    }
}

- (BOOL)isSideTransitioning:(IIViewDeckSide)viewDeckSide {
    return (([self isSideClosed:viewDeckSide] == NO) &&
            ([self isSideOpen:viewDeckSide] == NO));
}

- (BOOL)openSideView:(IIViewDeckSide)side
            animated:(BOOL)animated
          completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:side
                     animated:animated
                     duration:kIIViewDeckDefaultDuration
                   completion:completed];
}

- (BOOL)openSideView:(IIViewDeckSide)side
            animated:(BOOL)animated
            duration:(NSTimeInterval)duration
          completion:(IIViewDeckControllerBlock)completed {
    // if there's no controller or we're already open, just run the completion and say we're done.
    if (([self controllerForSide:side] == nil) ||
        [self isSideOpen:side]) {
        if (completed) completed(self, YES);
        return YES;
    }
    
    // check the delegate to allow opening
    if ([self checkCanOpenSide:side] == NO) {
        if (completed){ completed(self, NO); }
        return NO;
    };
    
    if ([self isSideClosed:[self oppositeOfSide:side]] == NO) {
        return [self toggleOpenViewAnimated:animated
                                 completion:completed];
    }
    
    if (duration == kIIViewDeckDefaultDuration) duration = [self openSlideDuration:animated];
    
    //we may be modifying these options below
    __block UIViewAnimationOptions options =  UIViewAnimationOptionLayoutSubviews | UIViewAnimationOptionBeginFromCurrentState;
    
    IIViewDeckControllerBlock finish = ^(IIViewDeckController *controller, BOOL success) {
        if (success == NO) {
            if (completed != nil) {
                completed(self, NO);
            }
            return;
        }
        
        [self notifyWillOpenSide:side
                        animated:animated];

        CGFloat offset = [self ledgeOffsetForSide:side];
        IIViewDeckOffsetOrientation orientation =
        IIViewDeckOffsetOrientationFromIIViewDeckSide(side);

        [UIView
         animateWithDuration:duration
         delay:0
         options:options
         animations:^{

             [self notifyWillChangeOffset:offset orientation:orientation panning:NO];

             UIViewController *sideViewController = [self controllerForSide:side];
             sideViewController.view.hidden = NO;
             [self setSlidingFrameForOffset:offset
                             forOrientation:orientation];
             [self centerViewHidden];
         } completion:^(BOOL finished) {
             if (completed){ completed(self, YES); }
             
             [self notifyDidOpenSide:side
                            animated:animated];
             UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
         }];
    };
    
    if ([self isSideClosed:side]) {
        options |= UIViewAnimationOptionCurveEaseIn;
        // try to close any open view first
        return [self closeOpenViewAnimated:animated
                                completion:finish];
    }
    else {
        options |= UIViewAnimationOptionCurveEaseOut;
        finish(self, YES);
        return YES;
    }
}

- (BOOL)openSideView:(IIViewDeckSide)side
        bounceOffset:(CGFloat)bounceOffset
        targetOffset:(CGFloat)targetOffset
             bounced:(IIViewDeckControllerBounceBlock)bounced
          completion:(IIViewDeckControllerBlock)completed {
    BOOL animated = YES;
    
    // if there's no controller or we're already open, just run the completion and say we're done.
    if (([self controllerForSide:side] == nil) ||
        [self isSideOpen:side]) {
        if (completed){ completed(self, YES); }
        return YES;
    }
    
    // check the delegate to allow opening
    if ([self checkCanOpenSide:side] == NO) {
        if (completed){ completed(self, NO); }
        return NO;
    };
    
    UIViewAnimationOptions options = UIViewAnimationOptionLayoutSubviews | UIViewAnimationOptionBeginFromCurrentState;
    if ([self isSideClosed:side]){
        options |= UIViewAnimationOptionCurveEaseIn;
    }
    else{
        options |= UIViewAnimationOptionCurveEaseOut;
    }
    
    IIViewDeckControllerBlock closeCompletion = ^(IIViewDeckController *controller, BOOL success) {
        if (!success) {
            if (completed) completed(self, NO);
            return;
        }
        
        CGFloat longFactor = _bounceDurationFactor ? _bounceDurationFactor : 1;
        CGFloat shortFactor = _bounceOpenSideDurationFactor ? _bounceOpenSideDurationFactor : (_bounceDurationFactor ? 1-_bounceDurationFactor : 1);
        
        // first open the view completely, run the block (to allow changes)
        [self notifyWillOpenSide:side animated:animated];
        [UIView
         animateWithDuration:[self openSlideDuration:YES]*longFactor
         delay:0
         options:options
         animations:^{
             [self controllerForSide:side].view.hidden = NO;
             [self setSlidingFrameForOffset:bounceOffset
                             forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(side)];
         }
         completion:^(BOOL finished) {
             [self centerViewHidden];
             // run block if it's defined
             if (bounced){
                 bounced(self);
             }
             
             [self performDelegate:@selector(viewDeckController:didBounceViewSide:openingController:)
                              side:side
                        controller:_controllers[side]];
             
             // now slide the view back to the ledge position
             [UIView
              animateWithDuration:[self openSlideDuration:YES]*shortFactor
              delay:0
              options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionLayoutSubviews | UIViewAnimationOptionBeginFromCurrentState
              animations:^{
                  [self setSlidingFrameForOffset:targetOffset
                                  forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(side)];
              }
              completion:^(BOOL finished) {
                  if (completed) completed(self, YES);
                  [self notifyDidOpenSide:side
                                 animated:animated];
                  UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
              }];
         }];
    };
    
    return [self closeOpenViewAnimated:animated
                            completion:closeCompletion];
}


- (BOOL)closeSideView:(IIViewDeckSide)side
             animated:(BOOL)animated
           completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:side
                      animated:animated
                      duration:kIIViewDeckDefaultDuration
                    completion:completed];
}

- (BOOL)closeSideView:(IIViewDeckSide)side
             animated:(BOOL)animated
             duration:(NSTimeInterval)duration
           completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:side]) {
        if (completed){
            completed(self, YES);
        }
        return YES;
    }
    
    // check the delegate to allow closing
    if ([self checkCanCloseSide:side] == NO) {
        if (completed){
            completed(self, NO);
        }
        return NO;
    }
    
    if (duration == kIIViewDeckDefaultDuration){
        duration = [self closeSlideDuration:animated];
    }
    
    UIViewAnimationOptions options = UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionLayoutSubviews | UIViewAnimationOptionBeginFromCurrentState;
    if ([self isSideOpen:side]){
        options |= UIViewAnimationOptionCurveEaseIn;
    }
    else{
        options |= UIViewAnimationOptionCurveEaseOut;
    }
    
    [self notifyWillCloseSide:side
                     animated:animated];
    [UIView
     animateWithDuration:duration
     delay:0
     options:options
     animations:^{
         [self notifyClosingAnimationSide:side animated:animated];
         [self setSlidingFrameForOffset:0
                         forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(side)];
         [self centerViewVisible];
     }
     completion:^(BOOL finished) {
         [self hideAppropriateSideViews];
         
         if (completed){
             completed(self, YES);
         }
         
         [self notifyDidCloseSide:side
                         animated:animated];
         UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
     }];
    
    return YES;
}

- (CGFloat)openSlideDuration:(BOOL)animated {
    return animated ? self.openSlideAnimationDuration : 0;
}

- (CGFloat)closeSlideDuration:(BOOL)animated {
    return animated ? self.closeSlideAnimationDuration : 0;
}


- (BOOL)closeSideView:(IIViewDeckSide)side
         bounceOffset:(CGFloat)bounceOffset
              bounced:(IIViewDeckControllerBounceBlock)bounced
           completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:side]) {
        if (completed){
            completed(self, YES);
        }
        return YES;
    }
    
    // check the delegate to allow closing
    if ([self checkCanCloseSide:side] == NO) {
        if (completed){
            completed(self, NO);
        }
        return NO;
    }
    
    UIViewAnimationOptions options = UIViewAnimationOptionLayoutSubviews | UIViewAnimationOptionBeginFromCurrentState;
    if ([self isSideOpen:side]){
        options |= UIViewAnimationOptionCurveEaseIn;
    }
    else{
        options |= UIViewAnimationOptionCurveEaseInOut;
    }
    
    BOOL animated = YES;
    
    CGFloat longFactor = _bounceDurationFactor ? _bounceDurationFactor : 1;
    CGFloat shortFactor = _bounceOpenSideDurationFactor ? _bounceOpenSideDurationFactor : (_bounceDurationFactor ? 1-_bounceDurationFactor : 1);
    
    // first open the view completely, run the block (to allow changes) and close it again.
    [self notifyWillCloseSide:side
                     animated:animated];
    [UIView
     animateWithDuration:[self openSlideDuration:YES]*shortFactor
     delay:0
     options:options
     animations:^{
         [self setSlidingFrameForOffset:bounceOffset
                         forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(side)];
     }
     completion:^(BOOL finished) {
         // run block if it's defined
         if (bounced){
             bounced(self);
         }
         [self performDelegate:@selector(viewDeckController:didBounceViewSide:closingController:)
                          side:side
                    controller:_controllers[side]];
         
         [UIView
          animateWithDuration:[self closeSlideDuration:YES]*longFactor
          delay:0
          options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionLayoutSubviews
          animations:^{
              [self setSlidingFrameForOffset:0
                              forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(side)];
              [self centerViewVisible];
          }
          completion:^(BOOL finished2) {
              [self hideAppropriateSideViews];
              if (completed){
                  completed(self, YES);
              }
              [self notifyDidCloseSide:side
                              animated:animated];
              UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
          }];
     }];
    
    return YES;
}

- (void)setCenterController:(UIViewController *)newCenterController withScootAnimationToSide:(IIViewDeckSide)side{
    if ( (newCenterController != nil) &&
         ([newCenterController isEqual:self.centerController] == NO)) {
        
        CGRect frame;
        frame.size = self.centerView.frame.size;
        
        switch (side) {
            case IIViewDeckSideBottom:
                frame.origin = CGPointMake(0.f,
                                           self.centerView.frame.size.height);
                break;
            case IIViewDeckSideTop:
                frame.origin = CGPointMake(0.f,
                                           -self.centerView.frame.size.height);
                break;
            case IIViewDeckSideLeft:
                frame.origin = CGPointMake(-self.centerView.frame.size.width,
                                           0.f);
                break;
            case IIViewDeckSideRight:
                frame.origin = CGPointMake(self.centerView.frame.size.width,
                                           0.f);
                break;
            default:
                frame.origin = CGPointZero;
                break;
        }
        
        [self revealNewCenterController:newCenterController
                  transitionAnimation:^{
            self.centerController.view.frame = frame;
        }];
    }
}

#pragma mark - Left Side

- (BOOL)toggleLeftView {
    return [self toggleLeftViewAnimated:YES];
}

- (BOOL)openLeftView {
    return [self openLeftViewAnimated:YES];
}

- (BOOL)closeLeftView {
    return [self closeLeftViewAnimated:YES];
}

- (BOOL)toggleLeftViewAnimated:(BOOL)animated {
    return [self toggleLeftViewAnimated:animated
                             completion:nil];
}

- (BOOL)toggleLeftViewAnimated:(BOOL)animated
                    completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:IIViewDeckSideLeft]){
        return [self openLeftViewAnimated:animated
                               completion:completed];
    }
    else{
        return [self closeLeftViewAnimated:animated
                                completion:completed];
    }
}

- (BOOL)openLeftViewAnimated:(BOOL)animated {
    return [self openLeftViewAnimated:animated
                           completion:nil];
}

- (BOOL)openLeftViewAnimated:(BOOL)animated
                  completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideLeft
                     animated:animated
                   completion:completed];
}

- (BOOL)openLeftViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self openLeftViewBouncing:bounced
                           completion:nil];
}

- (BOOL)openLeftViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                  completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideLeft
                 bounceOffset:self.referenceBounds.size.width
                 targetOffset:self.referenceBounds.size.width - _ledge[IIViewDeckSideLeft]
                      bounced:bounced
                   completion:completed];
}

- (BOOL)closeLeftViewAnimated:(BOOL)animated {
    return [self closeLeftViewAnimated:animated
                            completion:nil];
}

- (BOOL)closeLeftViewAnimated:(BOOL)animated
                   completion:(IIViewDeckControllerBlock)completed {
    return [self closeLeftViewAnimated:animated
                              duration:kIIViewDeckDefaultDuration
                            completion:completed];
}

- (BOOL)closeLeftViewAnimated:(BOOL)animated
                     duration:(NSTimeInterval)duration
                   completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideLeft
                      animated:animated
                      duration:duration
                    completion:completed];
}

- (BOOL)closeLeftViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self closeLeftViewBouncing:bounced
                            completion:nil];
}

- (BOOL)closeLeftViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                   completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideLeft
                  bounceOffset:self.referenceBounds.size.width
                       bounced:bounced
                    completion:completed];
}

#pragma mark - Right Side

- (BOOL)toggleRightView {
    return [self toggleRightViewAnimated:YES];
}

- (BOOL)openRightView {
    return [self openRightViewAnimated:YES];
}

- (BOOL)closeRightView {
    return [self closeRightViewAnimated:YES];
}

- (BOOL)toggleRightViewAnimated:(BOOL)animated {
    return [self toggleRightViewAnimated:animated
                              completion:nil];
}

- (BOOL)toggleRightViewAnimated:(BOOL)animated
                     completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:IIViewDeckSideRight]){
        return [self openRightViewAnimated:animated
                                completion:completed];
    }
    else{
        return [self closeRightViewAnimated:animated
                                 completion:completed];
    }
}

- (BOOL)openRightViewAnimated:(BOOL)animated {
    return [self openRightViewAnimated:animated
                            completion:nil];
}

- (BOOL)openRightViewAnimated:(BOOL)animated
                   completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideRight
                     animated:animated
                   completion:completed];
}

- (BOOL)openRightViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self openRightViewBouncing:bounced
                            completion:nil];
}

- (BOOL)openRightViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                   completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideRight
                 bounceOffset:-self.referenceBounds.size.width
                 targetOffset:_ledge[IIViewDeckSideRight] - self.referenceBounds.size.width
                      bounced:bounced
                   completion:completed];
}

- (BOOL)closeRightViewAnimated:(BOOL)animated {
    return [self closeRightViewAnimated:animated
                             completion:nil];
}

- (BOOL)closeRightViewAnimated:(BOOL)animated
                    completion:(IIViewDeckControllerBlock)completed {
    return [self closeRightViewAnimated:animated
                               duration:kIIViewDeckDefaultDuration
                             completion:completed];
}

- (BOOL)closeRightViewAnimated:(BOOL)animated
                      duration:(NSTimeInterval)duration
                    completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideRight
                      animated:animated
                      duration:duration
                    completion:completed];
}

- (BOOL)closeRightViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self closeRightViewBouncing:bounced
                             completion:nil];
}

- (BOOL)closeRightViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                    completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideRight
                  bounceOffset:-self.referenceBounds.size.width
                       bounced:bounced
                    completion:completed];
}

#pragma mark - right view, special case for navigation stuff

- (BOOL)canRightViewPushViewControllerOverCenterController {
    return [self.centerController isKindOfClass:[UINavigationController class]];
}

- (void)rightViewPushViewControllerOverCenterController:(UIViewController*)controller {
    NSAssert1([self.centerController isKindOfClass:[UINavigationController class]],
              @"cannot %@ when center controller is not a navigation controller",
              NSStringFromSelector(_cmd));
    
    UIView* view = self.view;
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, YES, 0.0);
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    [view.layer renderInContext:context];
    UIImage *deckshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    UIImageView* shotView = [[UIImageView alloc] initWithImage:deckshot];
    shotView.frame = view.frame;
    [view.superview addSubview:shotView];
    CGRect targetFrame = view.frame;
    view.frame = CGRectOffset(view.frame, view.frame.size.width, 0);
    
    [self closeRightViewAnimated:NO];
    UINavigationController* navController = self.centerController.navigationController ? self.centerController.navigationController :(UINavigationController*)self.centerController;
    [navController pushViewController:controller animated:NO];
    
    [UIView
     animateWithDuration:0.3
     delay:0
     options:0
     animations:^{
         shotView.frame = CGRectOffset(shotView.frame, -view.frame.size.width, 0);
         view.frame = targetFrame;
     }
     completion:^(BOOL finished) {
         [shotView removeFromSuperview];
     }];
}

#pragma mark - Top Side

- (BOOL)toggleTopView {
    return [self toggleTopViewAnimated:YES];
}

- (BOOL)openTopView {
    return [self openTopViewAnimated:YES];
}

- (BOOL)closeTopView {
    return [self closeTopViewAnimated:YES];
}

- (BOOL)toggleTopViewAnimated:(BOOL)animated {
    return [self toggleTopViewAnimated:animated
                            completion:nil];
}

- (BOOL)toggleTopViewAnimated:(BOOL)animated
                   completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:IIViewDeckSideTop]){
        return [self openTopViewAnimated:animated
                              completion:completed];
    }
    else{
        return [self closeTopViewAnimated:animated
                               completion:completed];
    }
}

- (BOOL)openTopViewAnimated:(BOOL)animated {
    return [self openTopViewAnimated:animated
                          completion:nil];
}

- (BOOL)openTopViewAnimated:(BOOL)animated
                 completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideTop
                     animated:animated
                   completion:completed];
}

- (BOOL)openTopViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self openTopViewBouncing:bounced
                          completion:nil];
}

- (BOOL)openTopViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                 completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideTop
                 bounceOffset:self.referenceBounds.size.height
                 targetOffset:self.referenceBounds.size.height - _ledge[IIViewDeckSideTop]
                      bounced:bounced
                   completion:completed];
}

- (BOOL)closeTopViewAnimated:(BOOL)animated {
    return [self closeTopViewAnimated:animated
                           completion:nil];
}

- (BOOL)closeTopViewAnimated:(BOOL)animated
                  completion:(IIViewDeckControllerBlock)completed {
    return [self closeTopViewAnimated:animated
                             duration:kIIViewDeckDefaultDuration
                           completion:completed];
}

- (BOOL)closeTopViewAnimated:(BOOL)animated
                    duration:(NSTimeInterval)duration
                  completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideTop
                      animated:animated
                      duration:duration
                    completion:completed];
}

- (BOOL)closeTopViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self closeTopViewBouncing:bounced
                           completion:nil];
}

- (BOOL)closeTopViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                  completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideTop
                  bounceOffset:self.referenceBounds.size.height
                       bounced:bounced
                    completion:completed];
}


#pragma mark - Bottom Side

- (BOOL)toggleBottomView {
    return [self toggleBottomViewAnimated:YES];
}

- (BOOL)openBottomView {
    return [self openBottomViewAnimated:YES];
}

- (BOOL)closeBottomView {
    return [self closeBottomViewAnimated:YES];
}

- (BOOL)toggleBottomViewAnimated:(BOOL)animated {
    return [self toggleBottomViewAnimated:animated
                               completion:nil];
}

- (BOOL)toggleBottomViewAnimated:(BOOL)animated
                      completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:IIViewDeckSideBottom]){
        return [self openBottomViewAnimated:animated
                                 completion:completed];
    }
    else{
        return [self closeBottomViewAnimated:animated
                                  completion:completed];
    }
}

- (BOOL)openBottomViewAnimated:(BOOL)animated {
    return [self openBottomViewAnimated:animated
                             completion:nil];
}

- (BOOL)openBottomViewAnimated:(BOOL)animated
                    completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideBottom
                     animated:animated
                   completion:completed];
}

- (BOOL)openBottomViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self openBottomViewBouncing:bounced
                             completion:nil];
}

- (BOOL)openBottomViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                    completion:(IIViewDeckControllerBlock)completed {
    return [self openSideView:IIViewDeckSideBottom
                 bounceOffset:-self.referenceBounds.size.height
                 targetOffset:_ledge[IIViewDeckSideBottom] - self.referenceBounds.size.height
                      bounced:bounced
                   completion:completed];
}

- (BOOL)closeBottomViewAnimated:(BOOL)animated {
    return [self closeBottomViewAnimated:animated
                              completion:nil];
}

- (BOOL)closeBottomViewAnimated:(BOOL)animated
                     completion:(IIViewDeckControllerBlock)completed {
    return [self closeBottomViewAnimated:animated
                                duration:kIIViewDeckDefaultDuration
                              completion:completed];
}

- (BOOL)closeBottomViewAnimated:(BOOL)animated
                       duration:(NSTimeInterval)duration
                     completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideBottom
                      animated:animated
                      duration:duration
                    completion:completed];
}

- (BOOL)closeBottomViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self closeBottomViewBouncing:bounced
                              completion:nil];
}

- (BOOL)closeBottomViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                     completion:(IIViewDeckControllerBlock)completed {
    return [self closeSideView:IIViewDeckSideBottom
                  bounceOffset:-self.referenceBounds.size.height
                       bounced:bounced
                    completion:completed];
}

#pragma mark - Side Bouncing

- (BOOL)previewBounceView:(IIViewDeckSide)viewDeckSide {
    return [self previewBounceView:viewDeckSide
                    withCompletion:nil];
}

- (BOOL)previewBounceView:(IIViewDeckSide)viewDeckSide
           withCompletion:(IIViewDeckControllerBlock)completed {
    return [self previewBounceView:viewDeckSide
                        toDistance:40.0f
                          duration:1.2f
                      callDelegate:YES
                        completion:completed];
}

- (BOOL)previewBounceView:(IIViewDeckSide)viewDeckSide
               toDistance:(CGFloat)distance
                 duration:(NSTimeInterval)duration
             callDelegate:(BOOL)callDelegate
               completion:(IIViewDeckControllerBlock)completed {
    return [self previewBounceView:viewDeckSide
                        toDistance:distance
                          duration:duration
                   numberOfBounces:4.0f
                     dampingFactor:0.40f
                      callDelegate:callDelegate
                        completion:completed];
}

- (BOOL)previewBounceView:(IIViewDeckSide)viewDeckSide
               toDistance:(CGFloat)distance
                 duration:(NSTimeInterval)duration
          numberOfBounces:(CGFloat)numberOfBounces
            dampingFactor:(CGFloat)zeta
             callDelegate:(BOOL)callDelegate
               completion:(IIViewDeckControllerBlock)completed {
    // Check if the requested side to bounce is nil, or if it's already open
    if (([self controllerForSide:viewDeckSide] == nil) ||
        [self isSideOpen:viewDeckSide]){
        return NO;
    }
    
    // check the delegate to allow bouncing
    if (callDelegate &&
        ([self checkDelegate:@selector(viewDeckController:shouldPreviewBounceViewSide:)
                        side:viewDeckSide] == NO)){
        return NO;
    }
    // also close any view that's open. Since the delegate can cancel the close, check the result.
    if (callDelegate &&
        [self isAnySideOpen]) {
        if ([self toggleOpenViewAnimated:YES] == NO){
            return NO;
        }
    }
    // check for in-flight preview bounce animation, do not add another if so
    if ([self.slidingControllerView.layer animationForKey:@"previewBounceAnimation"]) {
        return NO;
    }
    
    NSArray *animationValues = [self bouncingValuesForViewSide:viewDeckSide
                                                 maximumBounce:distance
                                               numberOfBounces:numberOfBounces
                                                 dampingFactor:zeta
                                                      duration:duration];
    if (animationValues == nil) {
        return NO;
    }
    
    UIViewController *previewController = [self controllerForSide:viewDeckSide];
    NSString *keyPath = @"position.x";
    
    if ((viewDeckSide == IIViewDeckSideBottom) ||
        (viewDeckSide == IIViewDeckSideTop)) {
        keyPath = @"position.y";
    }
    
    CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:keyPath];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    animation.duration = duration;
    animation.values = animationValues;
    animation.removedOnCompletion = YES;
    
    previewController.view.hidden = NO;
    
    [CATransaction begin];
    [CATransaction setValue:[NSNumber numberWithFloat:duration]
                     forKey:kCATransactionAnimationDuration];
    [CATransaction setCompletionBlock:^{
        // only re-hide controller if the view has not been panned mid-animation
        if (_offset == 0.0f) {
            previewController.view.hidden = YES;
        }
        
        // perform completion and delegate call
        if (completed){
            completed(self, YES);
        }
        if (callDelegate){
            [self performDelegate:@selector(viewDeckController:didPreviewBounceViewSide:)
                             side:viewDeckSide
                         animated:YES];
        }
    }];
    
    [self.slidingControllerView.layer addAnimation:animation
                                            forKey:@"previewBounceAnimation"];
    
    // Inform delegate
    if (callDelegate){
        [self performDelegate:@selector(viewDeckController:willPreviewBounceViewSide:animated:) side:viewDeckSide animated:YES];
    }
    
    // Commit animation
    [CATransaction commit];
    
    return YES;
}

- (NSArray *)bouncingValuesForViewSide:(IIViewDeckSide)viewDeckSide
                         maximumBounce:(CGFloat)maxBounce
                       numberOfBounces:(CGFloat)numberOfBounces
                         dampingFactor:(CGFloat)zeta
                              duration:(NSTimeInterval)duration {
    
    // Underdamped, Free Vibration of a SDOF System
    // u(t) = abs(e^(-zeta * wn * t) * ((Vo/wd) * sin(wd * t))
    
    // Vo, initial velocity, is calculated to provide the desired maxBounce and
    // animation duration. The damped period (wd) and distance of the maximum (first)
    // bounce can be controlled either via the initial condition Vo or the damping
    // factor zeta for a desired duration, Vo is simpler mathematically.
    
    NSUInteger steps = (NSUInteger)MIN(floorf(duration * 100.0f), 100);
    CGFloat time = 0.0;
    
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:steps];
    
    double offset = 0.0;
    CGFloat Td = (2.0f * duration) / numberOfBounces; //Damped period, calculated to give the number of bounces desired in the duration specified (2 bounces per Td)
    CGFloat wd = (2.0f * M_PI)/Td; // Damped frequency
    zeta = MIN(MAX(0.0001f, zeta), 0.9999f); // For an underdamped system, we must have 0 < zeta < 1
    CGFloat zetaFactor = sqrtf(1 - powf(zeta, 2.0f)); // Used in multiple places
    CGFloat wn = wd/zetaFactor; // Natural frequency
    CGFloat Vo = maxBounce * wd/(expf(-zeta/zetaFactor * (0.18f * Td) * wd) * sinf(0.18f * Td * wd));
    
    // Determine parameters based on direction
    CGFloat position = 0.0f;
    NSInteger direction = 1;
    switch (viewDeckSide) {
        case IIViewDeckSideLeft:
            position = self.slidingControllerView.layer.position.x;
            direction = 1;
            break;
            
        case IIViewDeckSideRight:
            position = self.slidingControllerView.layer.position.x;
            direction = -1;
            break;
            
        case IIViewDeckSideTop:
            position = self.slidingControllerView.layer.position.y;
            direction = 1;
            break;
            
        case IIViewDeckSideBottom:
            position = self.slidingControllerView.layer.position.y;
            direction = -1;
            break;
            
        default:
            return nil;
            break;
    }
    
    // Calculate steps
    for (NSInteger t = 0; t < steps; t++) {
        time = (t / (CGFloat)steps) * duration;
        offset = abs(expf(-zeta * wn * time) * ((Vo / wd) * sin(wd * time)));
        offset = direction * [self limitOffset:offset forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(viewDeckSide)] + position;
        [values addObject:[NSNumber numberWithFloat:offset]];
    }
    
    return values;
}

#pragma mark - toggling open view

- (BOOL)toggleOpenView {
    return [self toggleOpenViewAnimated:YES];
}

- (BOOL)toggleOpenViewAnimated:(BOOL)animated {
    return [self toggleOpenViewAnimated:animated
                             completion:nil];
}

- (BOOL)toggleOpenViewAnimated:(BOOL)animated
                    completion:(IIViewDeckControllerBlock)completed {
    IIViewDeckSide fromSide, toSide;
    CGFloat targetOffset;
    
    if ([self isSideOpen:IIViewDeckSideLeft]) {
        fromSide = IIViewDeckSideLeft;
        toSide = IIViewDeckSideRight;
        targetOffset = _ledge[IIViewDeckSideRight] - self.referenceBounds.size.width;
    }
    else if (([self isSideOpen:IIViewDeckSideRight])) {
        fromSide = IIViewDeckSideRight;
        toSide = IIViewDeckSideLeft;
        targetOffset = self.referenceBounds.size.width - _ledge[IIViewDeckSideLeft];
    }
    else if (([self isSideOpen:IIViewDeckSideTop])) {
        fromSide = IIViewDeckSideTop;
        toSide = IIViewDeckSideBottom;
        targetOffset = _ledge[IIViewDeckSideBottom] - self.referenceBounds.size.height;
    }
    else if (([self isSideOpen:IIViewDeckSideBottom])) {
        fromSide = IIViewDeckSideBottom;
        toSide = IIViewDeckSideTop;
        targetOffset = self.referenceBounds.size.height - _ledge[IIViewDeckSideTop];
    }
    else
        return NO;
    
    // check the delegate to allow closing and opening
    if (([self checkCanCloseSide:fromSide] == NO) &&
        ([self checkCanOpenSide:toSide] == NO)){
        return NO;
    }
    
    [self notifyWillCloseSide:fromSide
                     animated:animated];
    [UIView
     animateWithDuration:[self closeSlideDuration:animated]
     delay:0
     options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionLayoutSubviews
     animations:^{
         [self setSlidingFrameForOffset:0
                         forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(fromSide)];
     }
     completion:^(BOOL finished) {
         [self notifyWillOpenSide:toSide animated:animated];
         
         [UIView
          animateWithDuration:[self openSlideDuration:animated]
          delay:0
          options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionLayoutSubviews
          animations:^{
              [self setSlidingFrameForOffset:targetOffset
                              forOrientation:IIViewDeckOffsetOrientationFromIIViewDeckSide(toSide)];
          }
          completion:^(BOOL finished) {
              [self notifyDidOpenSide:toSide
                             animated:animated];
          }];
         
         [self hideAppropriateSideViews];
         [self notifyDidCloseSide:fromSide
                         animated:animated];
     }];
    
    return YES;
}


- (BOOL)closeOpenView {
    return [self closeOpenViewAnimated:YES];
}

- (BOOL)closeOpenViewAnimated:(BOOL)animated {
    return [self closeOpenViewAnimated:animated
                            completion:nil];
}

- (BOOL)closeOpenViewAnimated:(BOOL)animated
                   completion:(IIViewDeckControllerBlock)completed {
    return [self closeOpenViewAnimated:animated
                              duration:kIIViewDeckDefaultDuration
                            completion:completed];
}

- (BOOL)closeOpenViewAnimated:(BOOL)animated
                     duration:(NSTimeInterval)duration
                   completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideClosed:IIViewDeckSideLeft] == NO) {
        return [self closeLeftViewAnimated:animated
                                  duration:duration
                                completion:completed];
    }
    else if ([self isSideClosed:IIViewDeckSideRight] == NO) {
        return [self closeRightViewAnimated:animated
                                   duration:duration
                                 completion:completed];
    }
    else if ([self isSideClosed:IIViewDeckSideTop] == NO) {
        return [self closeTopViewAnimated:animated
                                 duration:duration
                               completion:completed];
    }
    else if ([self isSideClosed:IIViewDeckSideBottom] == NO) {
        return [self closeBottomViewAnimated:animated
                                    duration:duration
                                  completion:completed];
    }
    
    if (completed){
        completed(self, YES);
    }
    return YES;
}


- (BOOL)closeOpenViewBouncing:(IIViewDeckControllerBounceBlock)bounced {
    return [self closeOpenViewBouncing:bounced
                            completion:nil];
}

- (BOOL)closeOpenViewBouncing:(IIViewDeckControllerBounceBlock)bounced
                   completion:(IIViewDeckControllerBlock)completed {
    if ([self isSideOpen:IIViewDeckSideLeft]) {
        return [self closeLeftViewBouncing:bounced
                                completion:completed];
    }
    else if (([self isSideOpen:IIViewDeckSideRight])) {
        return [self closeRightViewBouncing:bounced
                                 completion:completed];
    }
    else if (([self isSideOpen:IIViewDeckSideTop])) {
        return [self closeTopViewBouncing:bounced
                               completion:completed];
    }
    else if (([self isSideOpen:IIViewDeckSideBottom])) {
        return [self closeBottomViewBouncing:bounced
                                  completion:completed];
    }
    
    if (completed) completed(self, YES);
    return YES;
}


#pragma mark - Rotation

- (void)relayRotationMethod:(void(^)(UIViewController* controller))relay {
    // first check ios6. we return yes in the method, so don't bother
    BOOL ios6 = ([super respondsToSelector:@selector(shouldAutomaticallyForwardRotationMethods)] &&
                 [self shouldAutomaticallyForwardRotationMethods]);
    if (ios6) return;
    
    // no need to check for ios5, since we already said that we'd handle it ourselves.
    relay(self.centerController);
    relay(self.leftController);
    relay(self.rightController);
    relay(self.topController);
    relay(self.bottomController);
}

#pragma mark - Center View Hidden

- (void)centerViewVisible {
    [self removePanGestureRecognizers];
    [self removeTapGestureRecognizers];
    
    self.centerTapperView = nil;
    
    [self addPanGestureRecognizers];
    [self applyShadowToSlidingViewAnimated:YES];
}

- (void)centerViewHidden {
    if (IIViewDeckIsInteractiveWhenOpen(self.centerhiddenInteractivity)) {
        [self removePanGestureRecognizers];
        if (self.centerTapperView == nil) {
            self.centerTapperView = [[UIView alloc] initWithFrame:self.centerController.view.bounds];
            self.centerTapperView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.centerTapperView.exclusiveTouch = NO;
            
            self.centerTapperView.backgroundColor = [UIColor clearColor];
        }
        
        [self.centerController.view addSubview:self.centerTapperView];
        self.centerTapperView.accessibilityLabel = self.centerTapperAccessibilityLabel;
        
        if([self hasNavigationBar]){
            CGRect centerRect = self.centerTapperView.frame;
            self.centerTapperView.frame = CGRectMake(0, 44.0, centerRect.size.width, centerRect.size.height-44.0);
        }
        
        [self addPanGestureRecognizers];
        [self addTapGestureRecognizers];
    }
    
    [self applyShadowToSlidingViewAnimated:YES];
}

- (void)centerTapped {
    if (IIViewDeckCanTapToClose(self.centerhiddenInteractivity)) {
        if ((self.leftController != nil) &&
            (CGRectGetMinX(self.slidingControllerView.frame) > 0.f)) {
            if (self.centerhiddenInteractivity == IIViewDeckCenterHiddenInteractionTapToClose){
                [self closeLeftView];
            }
            else{
                [self closeLeftViewBouncing:nil];
            }
        }
        if ((self.rightController != nil) &&
            (CGRectGetMinX(self.slidingControllerView.frame) < 0.f)) {
            if (self.centerhiddenInteractivity == IIViewDeckCenterHiddenInteractionTapToClose){
                [self closeRightView];
            }
            else{
                [self closeRightViewBouncing:nil];
            }
        }
        if ((self.bottomController != nil) &&
            (CGRectGetMinY(self.slidingControllerView.frame) < 0.f)) {
            if (self.centerhiddenInteractivity == IIViewDeckCenterHiddenInteractionTapToClose){
                [self closeBottomView];
            }
            else{
                [self closeBottomViewBouncing:nil];
            }
        }
        
        if ((self.topController != nil) &&
            (CGRectGetMinY(self.slidingControllerView.frame) > 0.f)) {
            if (self.centerhiddenInteractivity == IIViewDeckCenterHiddenInteractionTapToClose){
                [self closeTopView];
            }
            else{
                [self closeTopViewBouncing:nil];
            }
        }
    }
}

#pragma mark - Panning

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)panner {
    if ((self.panningMode == IIViewDeckPanningModeNavigationBarOrOpenCenter) &&
        [panner.view isEqual:self.slidingControllerView] &&
        [self isAnySideOpen]){
        return NO;
    }
    
    if ((self.panningGestureDelegate != nil) &&
        [self.panningGestureDelegate respondsToSelector:@selector(gestureRecognizerShouldBegin:)]) {
        BOOL result = [self.panningGestureDelegate gestureRecognizerShouldBegin:panner];
        if (result == NO){
            return result;
        }
    }
    
    IIViewDeckOffsetOrientation orientation;
    CGPoint velocity = [panner velocityInView:self.referenceView];
    if (ABS(velocity.x) >= ABS(velocity.y)){
        orientation = IIViewDeckOrientationHorizontal;
    }
    else{
        orientation = IIViewDeckOrientationVertical;
    }
    
    CGFloat pv;
    IIViewDeckSide minSide, maxSide;
    if (orientation == IIViewDeckOrientationHorizontal) {
        minSide = IIViewDeckSideLeft;
        maxSide = IIViewDeckSideRight;
        pv = self.slidingControllerView.frame.origin.x;
    }
    else {
        minSide = IIViewDeckSideTop;
        maxSide = IIViewDeckSideBottom;
        pv = self.slidingControllerView.frame.origin.y;
    }
    
    if ((self.panningMode == IIViewDeckPanningModeDelegate) &&
        [self.delegate respondsToSelector:@selector(viewDeckController:shouldPan:)]) {
        if ([self.delegate viewDeckController:self shouldPan:panner] == NO){
            return NO;
        }
    }
    
    if (pv != 0){
        return YES;
    }
    
    CGFloat v = [self locationOfPanner:panner orientation:orientation];
    BOOL ok = YES;
    
    if (v > 0) {
        ok = [self checkCanOpenSide:minSide];
        if (ok == NO){
            [self closeSideView:minSide animated:NO completion:nil];
        }
    }
    else if (v < 0) {
        ok = [self checkCanOpenSide:maxSide];
        if (ok == NO){
            [self closeSideView:maxSide animated:NO completion:nil];
        }
    }
    
    return ok;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if ((self.panningGestureDelegate != nil) &&
        [self.panningGestureDelegate respondsToSelector:@selector(gestureRecognizer:shouldReceiveTouch:)]) {
        BOOL result = [self.panningGestureDelegate gestureRecognizer:gestureRecognizer
                                                  shouldReceiveTouch:touch];
        if (result == NO){
            return result;
        }
    }
    
    if ([[touch view] isKindOfClass:[UISlider class]]){
        return NO;
    }
    
    _panOrigin = self.slidingControllerView.frame.origin;
    return YES;
}

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ((self.panningGestureDelegate != nil) &&
        [self.panningGestureDelegate respondsToSelector:@selector(gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:)]) {
        return [self.panningGestureDelegate gestureRecognizer:gestureRecognizer
           shouldRecognizeSimultaneouslyWithGestureRecognizer:otherGestureRecognizer];
    }
    
    return NO;
}

- (CGFloat)locationOfPanner:(UIPanGestureRecognizer*)panner
                orientation:(IIViewDeckOffsetOrientation)orientation {
    CGPoint pan = [panner translationInView:self.referenceView];
    CGFloat ofs = orientation == IIViewDeckOrientationHorizontal ? (pan.x+_panOrigin.x) : (pan.y + _panOrigin.y);
    
    IIViewDeckSide minSide, maxSide;
    CGFloat max;
    if (orientation == IIViewDeckOrientationHorizontal) {
        minSide = IIViewDeckSideLeft;
        maxSide = IIViewDeckSideRight;
        max = self.referenceBounds.size.width;
    }
    else {
        minSide = IIViewDeckSideTop;
        maxSide = IIViewDeckSideBottom;
        max = self.referenceBounds.size.height;
    }
    if (!_controllers[minSide]) ofs = MIN(0, ofs);
    if (!_controllers[maxSide]) ofs = MAX(0, ofs);
    
    CGFloat lofs = MAX(MIN(ofs, max-_ledge[minSide]), -max+_ledge[maxSide]);
    
    if (self.elastic) {
        CGFloat dofs = ABS(ofs) - ABS(lofs);
        if (dofs > 0) {
            dofs = dofs / logf(dofs + 1) * 2;
            ofs = lofs + (ofs < 0 ? -dofs : dofs);
        }
    }
    else {
        ofs = lofs;
    }
    
    return [self limitOffset:ofs forOrientation:orientation];
}


- (void)panned:(UIPanGestureRecognizer*)panner {
    if (!_enabled){
        return;
    }
    
    if (_offset == 0 && panner.state == UIGestureRecognizerStateBegan) {
        CGPoint velocity = [panner velocityInView:self.referenceView];
        if (ABS(velocity.x) >= ABS(velocity.y)){
            [self panned:panner
             orientation:IIViewDeckOrientationHorizontal];
        }
        else{
            [self panned:panner
             orientation:IIViewDeckOrientationVertical];
        }
    }
    else {
        [self panned:panner
         orientation:_offsetOrientation];
    }
}

- (void)panned:(UIPanGestureRecognizer*)panner
   orientation:(IIViewDeckOffsetOrientation)orientation {
    CGFloat pv, m;
    IIViewDeckSide minSide, maxSide;
    if (orientation == IIViewDeckOrientationHorizontal) {
        pv = self.slidingControllerView.frame.origin.x;
        m = self.referenceBounds.size.width;
        minSide = IIViewDeckSideLeft;
        maxSide = IIViewDeckSideRight;
    }
    else {
        pv = self.slidingControllerView.frame.origin.y;
        m = self.referenceBounds.size.height;
        minSide = IIViewDeckSideTop;
        maxSide = IIViewDeckSideBottom;
    }
    CGFloat v = [self locationOfPanner:panner
                           orientation:orientation];
    
    IIViewDeckSide closeSide = IIViewDeckSideNone;
    IIViewDeckSide openSide = IIViewDeckSideNone;
    
    // if we move over a boundary while dragging, ...
    if ( (pv <= 0) &&
        (v >= 0) &&
        (pv != v) ) {
        // ... then we need to check if the other side can open.
        if (pv < 0) {
            if ([self checkCanCloseSide:maxSide] == NO){
                return;
            }
            [self notifyWillCloseSide:maxSide animated:NO];
            closeSide = maxSide;
        }
        
        if (v > 0) {
            if ([self checkCanOpenSide:minSide] == NO) {
                [self closeSideView:maxSide
                           animated:NO
                         completion:nil];
                return;
            }
            [self notifyWillOpenSide:minSide animated:NO];
            openSide = minSide;
        }
    }
    else if ( (pv >= 0) &&
             (v <= 0) &&
             (pv != v)) {
        if (pv > 0) {
            if ([self checkCanCloseSide:minSide] == NO){
                return;
            }
            [self notifyWillCloseSide:minSide animated:NO];
            closeSide = minSide;
        }
        
        if (v < 0) {
            if ([self checkCanOpenSide:maxSide] == NO) {
                [self closeSideView:minSide animated:NO completion:nil];
                return;
            }
            [self notifyWillOpenSide:maxSide animated:NO];
            openSide = maxSide;
        }
    }
    
    // Check for an in-flight bounce animation
    CAKeyframeAnimation *bounceAnimation = (CAKeyframeAnimation *)[self.slidingControllerView.layer animationForKey:@"previewBounceAnimation"];
    if (bounceAnimation != nil) {
        self.slidingControllerView.frame = [[self.slidingControllerView.layer presentationLayer] frame];
        [self.slidingControllerView.layer removeAnimationForKey:@"previewBounceAnimation"];
        [UIView
         animateWithDuration:0.3
         delay:0
         options:UIViewAnimationOptionLayoutSubviews | UIViewAnimationOptionBeginFromCurrentState
         animations:^{
             [self panToSlidingFrameForOffset:v forOrientation:orientation];
         }
         completion:nil];
    }
    else {
        [self panToSlidingFrameForOffset:v forOrientation:orientation];
    }
    
    if (panner.state == UIGestureRecognizerStateEnded ||
        panner.state == UIGestureRecognizerStateCancelled ||
        panner.state == UIGestureRecognizerStateFailed) {
        CGFloat sv = orientation == IIViewDeckOrientationHorizontal ? self.slidingControllerView.frame.origin.x : self.slidingControllerView.frame.origin.y;
        if (II_FLOAT_EQUAL(sv, 0.0f)){
            [self centerViewVisible];
        }
        else{
            [self centerViewHidden];
        }
        
        CGFloat lm3 = (m-_ledge[minSide]) / 3.0;
        CGFloat rm3 = (m-_ledge[maxSide]) / 3.0;
        CGPoint velocity = [panner velocityInView:self.referenceView];
        CGFloat orientationVelocity = orientation == IIViewDeckOrientationHorizontal ? velocity.x : velocity.y;
        if (ABS(orientationVelocity) < 500) {
            // small velocity, no movement
            if (v >= m - _ledge[minSide] - lm3) {
                [self openSideView:minSide
                          animated:YES
                        completion:nil];
            }
            else if (v <= _ledge[maxSide] + rm3 - m) {
                [self openSideView:maxSide
                          animated:YES
                        completion:nil];
            }
            else
                [self closeOpenView];
        }
        else if (orientationVelocity != 0.0f) {
            if (orientationVelocity < 0) {
                // swipe to the left
                if (v < 0) {
                    [self openSideView:maxSide
                              animated:YES
                            completion:nil];
                }
                else{
                    // Animation duration based on velocity
                    CGFloat pointsToAnimate = self.slidingControllerView.frame.origin.x;
                    NSTimeInterval animationDuration = durationToAnimate(pointsToAnimate, orientationVelocity);
                    
                    [self closeOpenViewAnimated:YES
                                       duration:animationDuration
                                     completion:nil];
                }
            }
            else if (orientationVelocity > 0) {
                // swipe to the right
                
                // Animation duration based on velocity
                CGFloat pointsToAnimate = fabsf(m - self.leftSize - self.slidingControllerView.frame.origin.x);
                NSTimeInterval animationDuration = durationToAnimate(pointsToAnimate, orientationVelocity);
                
                if (v > 0) {
                    [self openSideView:minSide
                              animated:YES
                              duration:animationDuration
                            completion:nil];
                }
                else
                    [self closeOpenViewAnimated:YES
                                       duration:animationDuration
                                     completion:nil];
            }
        }
    }
    else{
        [self hideAppropriateSideViews];
    }
    
    [self notifyDidCloseSide:closeSide animated:NO];
    [self notifyDidOpenSide:openSide animated:NO];
}


- (void)addPanGestureRecognizerToView:(UIView*)view {
    if (view == nil){
        return;
    }
    
    UIPanGestureRecognizer* panner = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    panner.cancelsTouchesInView = YES;
    panner.delegate = self;
    [view addGestureRecognizer:panner];
    [self.panGestureRecognizers addObject:panner];
}

- (void)addTapGestureRecognizerToView:(UIView*)view {
    if(view == nil){
        return;
    }
    
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(centerTapped)];
    tap.cancelsTouchesInView = YES;
    [view addGestureRecognizer:tap];
    [self.tapGestureRecognizers addObject:tap];
}

- (void)addPanGestureRecognizers {
    [self removePanGestureRecognizers];
    
    switch (_panningMode) {
        case IIViewDeckPanningModeNone:
            break;
            
        case IIViewDeckPanningModeFullView:
        case IIViewDeckPanningModeDelegate:
        case IIViewDeckPanningModeNavigationBarOrOpenCenter:
            [self addPanGestureRecognizerToView:self.slidingControllerView];
            // also add to disabled center
            if (self.centerTapperView != nil){
                [self addPanGestureRecognizerToView:self.centerTapperView];
            }
            // also add to navigationbar if present
            if ((self.navigationController != nil) &&
                (self.navigationController.navigationBarHidden == NO)) {
                [self addPanGestureRecognizerToView:self.navigationController.navigationBar];
            }
            break;
            
        case IIViewDeckPanningModeNavigationBar:
            if ((self.navigationController != nil) &&
                (self.navigationController.navigationBarHidden == NO)) {
                [self addPanGestureRecognizerToView:self.navigationController.navigationBar];
            }
            
            if ((self.centerController.navigationController != nil) &&
                (self.centerController.navigationController.navigationBarHidden == NO)) {
                [self addPanGestureRecognizerToView:self.centerController.navigationController.navigationBar];
            }
            
            if ([self.centerController isKindOfClass:[UINavigationController class]] &&
                (((UINavigationController*)self.centerController).navigationBarHidden == NO)) {
                [self addPanGestureRecognizerToView:((UINavigationController*)self.centerController).navigationBar];
            }
            break;
            
        case IIViewDeckPanningModeView:
            if (self.panningView != nil) {
                [self addPanGestureRecognizerToView:self.panningView];
            }
            break;
    }
}

- (void)addTapGestureRecognizers{
    [self removeTapGestureRecognizers];
    switch(_centerhiddenInteractivity){
        case IIViewDeckCenterHiddenInteractionTapToClose:
        case IIViewDeckCenterHiddenInteractionTapToCloseBouncing:
            [self addTapGestureRecognizerToView:self.centerTapperView];
            
            if ((self.navigationController != nil) &&
                (self.navigationController.navigationBarHidden == NO)) {
                [self addTapGestureRecognizerToView:self.navigationController.navigationBar];
            }
            
            if ((self.centerController.navigationController != nil) &&
                (self.centerController.navigationController.navigationBarHidden == NO)) {
                [self addTapGestureRecognizerToView:self.centerController.navigationController.navigationBar];
            }
            
            if ([self.centerController isKindOfClass:[UINavigationController class]] &&
                (((UINavigationController*)self.centerController).navigationBarHidden == NO)) {
                [self addTapGestureRecognizerToView:((UINavigationController*)self.centerController).navigationBar];
            }
            
            break;
        case IIViewDeckCenterHiddenInteractionNone:
        case IIViewDeckCenterHiddenInteractionFull:
        default:
            break;
    }
}

- (BOOL)hasNavigationBar{
    if ((self.navigationController != nil) &&
        (self.navigationController.navigationBarHidden == NO)) {
        return YES;
    }
    
    if ((self.centerController.navigationController != nil) &&
        (self.centerController.navigationController.navigationBarHidden == NO)) {
        return YES;
    }
    
    if ([self.centerController isKindOfClass:[UINavigationController class]] &&
        (((UINavigationController*)self.centerController).navigationBarHidden == NO)) {
        return YES;
    }
    
    return NO;
}

- (void)removePanGestureRecognizers {
    for (UIGestureRecognizer* panner in self.panGestureRecognizers) {
        [panner.view removeGestureRecognizer:panner];
    }
    [self.panGestureRecognizers removeAllObjects];
}

- (void)removeTapGestureRecognizers{
    for(UIGestureRecognizer * tap in self.tapGestureRecognizers){
        [tap.view removeGestureRecognizer:tap];
    }
    [self.tapGestureRecognizers removeAllObjects];
}

#pragma mark - Delegate convenience methods

- (BOOL)checkDelegate:(SEL)selector side:(IIViewDeckSide)viewDeckSide {
    BOOL ok = YES;
    // used typed message send to properly pass values
    BOOL (*objc_msgSendTyped)(id self, SEL _cmd, IIViewDeckController* foo, IIViewDeckSide viewDeckSide) = (void*)objc_msgSend;
    
    if (self.delegate && [self.delegate respondsToSelector:selector])
        ok = ok & objc_msgSendTyped(self.delegate, selector, self, viewDeckSide);
    
    if (_delegateMode != IIViewDeckDelegateModeDelegateOnly) {
        for (UIViewController* controller in self.controllers) {
            // check controller first
            if ([controller respondsToSelector:selector] && (id)controller != (id)self.delegate)
                ok = ok & objc_msgSendTyped(controller, selector, self, viewDeckSide);
            // if that fails, check if it's a navigation controller and use the top controller
            else if ([controller isKindOfClass:[UINavigationController class]]) {
                UIViewController* topController = ((UINavigationController*)controller).topViewController;
                if ([topController respondsToSelector:selector] && (id)topController != (id)self.delegate)
                    ok = ok & objc_msgSendTyped(topController, selector, self, viewDeckSide);
            }
        }
    }
    
    return ok;
}

- (void)performDelegate:(SEL)selector side:(IIViewDeckSide)viewDeckSide animated:(BOOL)animated {
    // used typed message send to properly pass values
    void (*objc_msgSendTyped)(id self, SEL _cmd, IIViewDeckController* foo, IIViewDeckSide viewDeckSide, BOOL animated) = (void*)objc_msgSend;
    
    if (self.delegate && [self.delegate respondsToSelector:selector]){
        objc_msgSendTyped(self.delegate, selector, self, viewDeckSide, animated);
    }
    
    if (_delegateMode == IIViewDeckDelegateModeDelegateOnly){
        return;
    }
    
    for (UIViewController* controller in self.controllers) {
        // check controller first
        if ([controller respondsToSelector:selector] && (id)controller != (id)self.delegate)
            objc_msgSendTyped(controller, selector, self, viewDeckSide, animated);
        // if that fails, check if it's a navigation controller and use the top controller
        else if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController* topController = ((UINavigationController*)controller).topViewController;
            if ([topController respondsToSelector:selector] && (id)topController != (id)self.delegate){
                objc_msgSendTyped(topController, selector, self, viewDeckSide, animated);
            }
        }
    }
}

- (void)performDelegate:(SEL)selector side:(IIViewDeckSide)viewDeckSide controller:(UIViewController*)controller {
    // used typed message send to properly pass values
    void (*objc_msgSendTyped)(id self, SEL _cmd, IIViewDeckController* foo, IIViewDeckSide viewDeckSide, UIViewController* controller) = (void*)objc_msgSend;
    
    if (self.delegate && [self.delegate respondsToSelector:selector]){
        objc_msgSendTyped(self.delegate, selector, self, viewDeckSide, controller);
    }
    
    if (_delegateMode == IIViewDeckDelegateModeDelegateOnly){
        return;
    }
    
    for (UIViewController* controller in self.controllers) {
        // check controller first
        if ([controller respondsToSelector:selector] && (id)controller != (id)self.delegate){
            objc_msgSendTyped(controller, selector, self, viewDeckSide, controller);
        }
        // if that fails, check if it's a navigation controller and use the top controller
        else if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController* topController = ((UINavigationController*)controller).topViewController;
            if ([topController respondsToSelector:selector] && (id)topController != (id)self.delegate){
                objc_msgSendTyped(topController, selector, self, viewDeckSide, controller);
            }
        }
    }
}

- (CGFloat)performDelegate:(SEL)selector ledge:(CGFloat)ledge side:(IIViewDeckSide)side {
    CGFloat (*objc_msgSendTyped)(id self, SEL _cmd, IIViewDeckController* foo, CGFloat ledge, IIViewDeckSide side) = (void*)objc_msgSend;
    if (self.delegate && [self.delegate respondsToSelector:selector]){
        ledge = objc_msgSendTyped(self.delegate, selector, self, ledge, side);
    }
    
    if (_delegateMode == IIViewDeckDelegateModeDelegateOnly){
        return ledge;
    }
    
    for (UIViewController* controller in self.controllers) {
        // check controller first
        if ([controller respondsToSelector:selector] && (id)controller != (id)self.delegate){
            ledge = objc_msgSendTyped(controller, selector, self, ledge, side);
        }
        
        // if that fails, check if it's a navigation controller and use the top controller
        else if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController* topController = ((UINavigationController*)controller).topViewController;
            if ([topController respondsToSelector:selector] && (id)topController != (id)self.delegate){
                ledge = objc_msgSendTyped(topController, selector, self, ledge, side);
            }
        }
    }
    
    return ledge;
}

- (void)performDelegate:(SEL)selector offset:(CGFloat)offset orientation:(IIViewDeckOffsetOrientation)orientation panning:(BOOL)panning {
    void (*objc_msgSendTyped)(id self, SEL _cmd, IIViewDeckController* foo, CGFloat offset, IIViewDeckOffsetOrientation orientation, BOOL panning) = (void*)objc_msgSend;
    if (self.delegate && [self.delegate respondsToSelector:selector]) {
        objc_msgSendTyped(self.delegate, selector, self, offset, orientation, panning);
    }
    
    if (_delegateMode == IIViewDeckDelegateModeDelegateOnly){
        return;
    }
    
    for (UIViewController* controller in self.controllers) {
        // check controller first
        if ([controller respondsToSelector:selector] && (id)controller != (id)self.delegate) {
            objc_msgSendTyped(controller, selector, self, offset, orientation, panning);
        }
        
        // if that fails, check if it's a navigation controller and use the top controller
        else if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController* topController = ((UINavigationController*)controller).topViewController;
            if ([topController respondsToSelector:selector] && (id)topController != (id)self.delegate) {
                objc_msgSendTyped(topController, selector, self, offset, orientation, panning);
            }
        }
    }
}


#pragma mark - Properties

- (void)setBounceDurationFactor:(CGFloat)bounceDurationFactor {
    _bounceDurationFactor = MIN(MAX(0, bounceDurationFactor), 0.99f);
}

- (void)setTitle:(NSString *)title {
    if (!II_STRING_EQUAL(title, self.title)) [super setTitle:title];
    if (!II_STRING_EQUAL(title, self.centerController.title)) self.centerController.title = title;
}

- (NSString*)title {
    return self.centerController.title;
}

- (void)setPanningMode:(IIViewDeckPanningMode)panningMode {
    if (_viewFirstAppeared) {
        [self removePanGestureRecognizers];
        _panningMode = panningMode;
        [self addPanGestureRecognizers];
    }
    else{
        _panningMode = panningMode;
    }
}

- (void)setPanningView:(UIView *)panningView {
    if (_panningView != panningView) {
        _panningView = panningView;
        
        if (_viewFirstAppeared && _panningMode == IIViewDeckPanningModeView){
            [self addPanGestureRecognizers];
        }
    }
}

- (void)setNavigationControllerBehavior:(IIViewDeckNavigationControllerBehavior)navigationControllerBehavior {
    if (!_viewFirstAppeared) {
        _navigationControllerBehavior = navigationControllerBehavior;
    }
    else {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot set navigationcontroller behavior when the view deck is already showing." userInfo:nil];
    }
}

- (void)setController:(UIViewController *)controller forSide:(IIViewDeckSide)side {
    UIViewController* prevController = _controllers[side];
    if (controller == prevController){
        return;
    }
    
    __block IIViewDeckSide currentSide = IIViewDeckSideNone;
    
    //finds the current side a given controller is on
    [self executeBlockOnSideControllers:^(UIViewController* sideController, IIViewDeckSide side) {
        if (controller == sideController){
            currentSide = side;
        }
    }];
    
    //empty initial implementations
    void(^beforeBlock)() = nil;
    IIViewDeckAppearanceBlock afterBlock = nil;
    
    if (_viewFirstAppeared) {
        beforeBlock = ^{
            [self notifyAppearanceForSide:side
                                 animated:NO
                                     from:IIViewDeckViewStateVisible
                                       to:IIViewDeckViewStateInTransition];
            [[self controllerForSide:side].view removeFromSuperview];
            [self notifyAppearanceForSide:side
                                 animated:NO
                                     from:IIViewDeckViewStateInTransition
                                       to:IIViewDeckViewStateHidden];
        };
        afterBlock = ^(UIViewController* controller) {
            [self notifyAppearanceForSide:side
                                 animated:NO
                                     from:IIViewDeckViewStateHidden
                                       to:IIViewDeckViewStateInTransition];
            [self hideAppropriateSideViews];
            controller.view.frame = self.referenceBounds;
            controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            if (self.slidingController){
                [self.referenceView insertSubview:controller.view
                                     belowSubview:self.slidingControllerView];
            }
            else{
                [self.referenceView addSubview:controller.view];
            }
            [self notifyAppearanceForSide:side
                                 animated:NO
                                     from:IIViewDeckViewStateInTransition
                                       to:IIViewDeckViewStateVisible];
        };
    }
    
    // start the transition
    if (prevController) {
        [prevController willMoveToParentViewController:nil];
        if (controller == self.centerController){
            self.centerController = nil;
        }
        if(beforeBlock != nil){
            beforeBlock();
        }
        if (currentSide != IIViewDeckSideNone){
            _controllers[currentSide] = nil;
        }
        [prevController setViewDeckController:nil];
        [prevController removeFromParentViewController];
        [prevController didMoveToParentViewController:nil];
    }
    
    // make the switch
    if (prevController != controller) {
        _controllers[side] = controller;
    }
    
    if (controller) {
        // and finish the transition
        UIViewController* parentController = (self.referenceView == self.view) ? self : [[self parentViewController] parentViewController];
        if (!parentController){
            parentController = self;
        }
        
        [parentController addChildViewController:controller];
        [controller setViewDeckController:self];
        
        if (afterBlock != nil) {
            afterBlock(controller);
        }
        
        [controller didMoveToParentViewController:parentController];
    }
}

- (UIViewController *)leftController {
    return [self controllerForSide:IIViewDeckSideLeft];
}

- (void)setLeftController:(UIViewController *)leftController {
    [self setController:leftController forSide:IIViewDeckSideLeft];
}

- (UIViewController *)rightController {
    return [self controllerForSide:IIViewDeckSideRight];
}

- (void)setRightController:(UIViewController *)rightController {
    [self setController:rightController forSide:IIViewDeckSideRight];
}

- (UIViewController *)topController {
    return [self controllerForSide:IIViewDeckSideTop];
}

- (void)setTopController:(UIViewController *)topController {
    [self setController:topController forSide:IIViewDeckSideTop];
}

- (UIViewController *)bottomController {
    return [self controllerForSide:IIViewDeckSideBottom];
}

- (void)setBottomController:(UIViewController *)bottomController {
    [self setController:bottomController forSide:IIViewDeckSideBottom];
}

- (void)revealNewCenterController:(UIViewController *)newCenterController
            transitionAnimation:(void(^)(void))animations{
    if ([_centerController isEqual:newCenterController]) {
        return;
    }
    
    //add new center controller below current one
    [newCenterController viewWillAppear:YES];
    [self addChildViewController:newCenterController];
    [self.centerView insertSubview:newCenterController.view belowSubview:self.centerController.view];
    newCenterController.view.frame = self.referenceBounds;
    
    [self prepareCenterForNewController:newCenterController shouldModifyViewHeirarchy:NO];
    [self.centerController viewWillDisappear:YES];
    [self restoreShadowToSlidingView];
    [self removePanGestureRecognizers];
    
    //animate current center to side
    [UIView
     animateWithDuration:kIIViewDeckDefaultScootAnimationDuration
     delay:0.f
     options:UIViewAnimationOptionCurveEaseOut
     animations:animations
     completion:^(BOOL finished) {
         //swap out current center for new center
         [newCenterController viewDidAppear:YES];
         
         [self.centerController.view removeFromSuperview];
         [self.centerController viewDidDisappear:YES];
         
         _centerController = newCenterController;
         
         CGRect finalFrame = CGRectMake(0,
                                      0,
                                      self.centerView.frame.size.width,
                                      self.centerView.frame.size.height);
         [self configureNewCenterControllerWithFrame:finalFrame modifyViewHeirarchy:NO];
         
         [newCenterController didMoveToParentViewController:self];
     }];
}

- (void)prepareCenterForNewController:(UIViewController *)centerController shouldModifyViewHeirarchy:(BOOL)shouldModifyHeirarchy{
    [_centerController willMoveToParentViewController:nil];
    
    //clean up ivars
    if ([centerController isEqual:self.leftController]) self.leftController = nil;
    if ([centerController isEqual:self.rightController]) self.rightController = nil;
    if ([centerController isEqual:self.topController]) self.topController = nil;
    if ([centerController isEqual:self.bottomController]) self.bottomController = nil;
    
    if (_viewFirstAppeared) {
        if (shouldModifyHeirarchy) {
            [_centerController viewWillDisappear:NO];
        }
        [self restoreShadowToSlidingView];
        [self removePanGestureRecognizers];
        
        if (shouldModifyHeirarchy) {
            [_centerController.view removeFromSuperview];
            [_centerController viewDidDisappear:NO];
            [self.centerView removeFromSuperview];
        }
    }
    
    @try {
        [_centerController removeObserver:self forKeyPath:@"title"];
        if (self.automaticallyUpdateTabBarItems) {
            [self removeTabBarObserversForCenterController];
        }
    }
    @catch (NSException *exception) {}
    
    [_centerController setViewDeckController:nil];
}

- (void)configureNewCenterControllerWithFrame:(CGRect)currentFrame modifyViewHeirarchy:(BOOL)modifyHeirarchy{
    [_centerController setViewDeckController:self];
    [_centerController addObserver:self forKeyPath:@"title" options:0 context:nil];
    self.title = _centerController.title;
    if (self.automaticallyUpdateTabBarItems) {
        [self addTabBarObserversForCenterController];
        self.hidesBottomBarWhenPushed = _centerController.hidesBottomBarWhenPushed;
    }
    
    if (_viewFirstAppeared) {
        if (modifyHeirarchy) {
            [self.view addSubview:self.centerView];
            [_centerController viewWillAppear:NO];
        }
        
        UINavigationController *navController = nil;
        if([_centerController isKindOfClass:[UINavigationController class]]){
            navController = (UINavigationController *)_centerController;
        }
        
        BOOL barHidden = NO;
        if (navController != nil && !navController.navigationBarHidden) {
            barHidden = YES;
            navController.navigationBarHidden = YES;
        }
        
        [self setSlidingAndReferenceViews];
        _centerController.view.frame = currentFrame;
        _centerController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _centerController.view.hidden = NO;
        
        if (modifyHeirarchy) {
            [self.centerView addSubview:_centerController.view];
        }
        
        if (barHidden) {
            navController.navigationBarHidden = NO;
        }
        
        [self addPanGestureRecognizers];
        [self applyShadowToSlidingViewAnimated:NO];
        
        if (modifyHeirarchy) {
            [_centerController viewDidAppear:NO];
        }
    }
}

- (void)setCenterController:(UIViewController *)centerController {
    if ([_centerController isEqual:centerController]) {
        return;
    }
    
    CGRect currentFrame = self.referenceBounds;
    
    // start the transition
    if (_centerController) {
        currentFrame = _centerController.view.frame;
        [self prepareCenterForNewController:centerController shouldModifyViewHeirarchy:YES];
        
        [_centerController removeFromParentViewController];
        [_centerController didMoveToParentViewController:nil];
    }
    
    // make the switch
    _centerController = centerController;
    
    if (_centerController) {
        // and finish the transition
        [self addChildViewController:_centerController];
        [self configureNewCenterControllerWithFrame:currentFrame modifyViewHeirarchy:YES];
        
        [_centerController didMoveToParentViewController:self];
        
        if ([self isAnySideOpen]) {
            [self centerViewHidden];
        }
    }
}

- (void)removeTabBarObserversForCenterController {
    @try {
        [_centerController removeObserver:self forKeyPath:@"tabBarItem.title"];
        [_centerController removeObserver:self forKeyPath:@"tabBarItem.image"];
        [_centerController removeObserver:self forKeyPath:@"hidesBottomBarWhenPushed"];
    }
    @catch (NSException *exception) {}
}

- (void)addTabBarObserversForCenterController {
    [_centerController addObserver:self forKeyPath:@"tabBarItem.title" options:0 context:nil];
    [_centerController addObserver:self forKeyPath:@"tabBarItem.image" options:0 context:nil];
    [_centerController addObserver:self forKeyPath:@"hidesBottomBarWhenPushed" options:0 context:nil];
    self.tabBarItem.title = _centerController.tabBarItem.title;
    self.tabBarItem.image = _centerController.tabBarItem.image;
}

- (void)setAutomaticallyUpdateTabBarItems:(BOOL)automaticallyUpdateTabBarItems {
    if (_automaticallyUpdateTabBarItems) {
        [self removeTabBarObserversForCenterController];
    }
    
    _automaticallyUpdateTabBarItems = automaticallyUpdateTabBarItems;
    
    if (_automaticallyUpdateTabBarItems) {
        [self addTabBarObserversForCenterController];
    }
}


- (BOOL)setSlidingAndReferenceViews {
    if ((self.navigationController != nil) &&
        (self.navigationControllerBehavior == IIViewDeckNavigationControllerBehaviorIntegrated)) {
        if ([self.navigationController.view superview]) {
            _slidingController = self.navigationController;
            self.referenceView = [self.navigationController.view superview];
            return YES;
        }
    }
    else {
        _slidingController = self.centerController;
        self.referenceView = self.view;
        return YES;
    }
    
    return NO;
}

- (UIView*)slidingControllerView {
    if ((self.navigationController != nil) &&
        (self.navigationControllerBehavior == IIViewDeckNavigationControllerBehaviorIntegrated)) {
        return self.slidingController.view;
    }
    else {
        return self.centerView;
    }
}

#pragma mark - Observation

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == _centerController) {
        if ([@"tabBarItem.title" isEqualToString:keyPath]) {
            self.tabBarItem.title = _centerController.tabBarItem.title;
            return;
        }
        
        if ([@"tabBarItem.image" isEqualToString:keyPath]) {
            self.tabBarItem.image = _centerController.tabBarItem.image;
            return;
        }
        
        if ([@"hidesBottomBarWhenPushed" isEqualToString:keyPath]) {
            self.hidesBottomBarWhenPushed = _centerController.hidesBottomBarWhenPushed;
            self.tabBarController.hidesBottomBarWhenPushed = _centerController.hidesBottomBarWhenPushed;
            return;
        }
    }
    
    if ([@"title" isEqualToString:keyPath]) {
        if (!II_STRING_EQUAL([super title], self.centerController.title)) {
            self.title = self.centerController.title;
        }
        return;
    }
    
    if ([keyPath isEqualToString:@"bounds"]) {
        [self setSlidingFrameForOffset:_offset forOrientation:_offsetOrientation];
        self.slidingControllerView.layer.shadowPath = [UIBezierPath bezierPathWithRect:self.referenceBounds].CGPath;
        
        UINavigationController* navController = nil;
        if([self.centerController isKindOfClass:[UINavigationController class]]){
            navController = (UINavigationController*)self.centerController;
        }
        
        if ((navController != nil) &&
            (navController.navigationBarHidden == NO)) {
            navController.navigationBarHidden = YES;
            navController.navigationBarHidden = NO;
        }
        return;
    }
}

#pragma mark - Shadow

- (void)restoreShadowToSlidingView {
    UIView* shadowedView = self.slidingControllerView;
    if (shadowedView == nil){
        return;
    }
    
    shadowedView.layer.shadowRadius = self.originalShadowRadius;
    shadowedView.layer.shadowOpacity = self.originalShadowOpacity;
    shadowedView.layer.shadowColor = [self.originalShadowColor CGColor];
    shadowedView.layer.shadowOffset = self.originalShadowOffset;
    shadowedView.layer.shadowPath = [self.originalShadowPath CGPath];
}

- (void)applyShadowToSlidingViewAnimated:(BOOL)animated {
    UIView* shadowedView = self.slidingControllerView;
    if (shadowedView == nil){
        return;
    }
    
    self.originalShadowRadius = shadowedView.layer.shadowRadius;
    self.originalShadowOpacity = shadowedView.layer.shadowOpacity;
    self.originalShadowColor = shadowedView.layer.shadowColor ? [UIColor colorWithCGColor:self.slidingControllerView.layer.shadowColor] : nil;
    self.originalShadowOffset = shadowedView.layer.shadowOffset;
    self.originalShadowPath = shadowedView.layer.shadowPath ? [UIBezierPath bezierPathWithCGPath:self.slidingControllerView.layer.shadowPath] : nil;
    
    if ([self.delegate respondsToSelector:@selector(viewDeckController:applyShadow:withBounds:)]) {
        [self.delegate viewDeckController:self
                              applyShadow:shadowedView.layer
                               withBounds:self.referenceBounds];
    }
    else {
        UIBezierPath* newShadowPath = [UIBezierPath bezierPathWithRect:shadowedView.bounds];
        shadowedView.layer.masksToBounds = NO;
        shadowedView.layer.shadowRadius = 10;
        shadowedView.layer.shadowOpacity = 0.5;
        shadowedView.layer.shadowColor = [[UIColor blackColor] CGColor];
        shadowedView.layer.shadowOffset = CGSizeZero;
        shadowedView.layer.shadowPath = [newShadowPath CGPath];
    }
}


@end

#pragma mark -

@implementation UIViewController (UIViewDeckItem)

@dynamic viewDeckController;

static const char* viewDeckControllerKey = "ViewDeckController";

- (IIViewDeckController*)viewDeckController_core {
    return objc_getAssociatedObject(self, viewDeckControllerKey);
}

- (IIViewDeckController*)viewDeckController {
    id result = [self viewDeckController_core];
    if ((result == nil) &&
        (self.navigationController != nil)){
        result = [self.navigationController viewDeckController];
    }
    if ((result == nil) &&
        [self respondsToSelector:@selector(wrapController)] &&
        (self.wrapController != nil)){
        result = [self.wrapController viewDeckController];
    }
    
    return result;
}

- (void)setViewDeckController:(IIViewDeckController*)viewDeckController {
    objc_setAssociatedObject(self, viewDeckControllerKey, viewDeckController, OBJC_ASSOCIATION_ASSIGN);
}

- (void)vdc_presentModalViewController:(UIViewController *)modalViewController animated:(BOOL)animated {
    UIViewController* controller = self.viewDeckController && (self.viewDeckController.navigationControllerBehavior == IIViewDeckNavigationControllerBehaviorIntegrated || ![self.viewDeckController.centerController isKindOfClass:[UINavigationController class]]) ? self.viewDeckController : self;
    [controller vdc_presentModalViewController:modalViewController animated:animated]; // when we get here, the vdc_ method is actually the old, real method
}

- (void)vdc_dismissModalViewControllerAnimated:(BOOL)animated {
    UIViewController* controller = self.viewDeckController ? self.viewDeckController : self;
    [controller vdc_dismissModalViewControllerAnimated:animated]; // when we get here, the vdc_ method is actually the old, real method
}

#ifdef __IPHONE_5_0

- (void)vdc_presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)animated completion:(void (^)(void))completion {
    UIViewController* controller = self.viewDeckController && (self.viewDeckController.navigationControllerBehavior == IIViewDeckNavigationControllerBehaviorIntegrated || ![self.viewDeckController.centerController isKindOfClass:[UINavigationController class]]) ? self.viewDeckController : self;
    [controller vdc_presentViewController:viewControllerToPresent animated:animated completion:completion]; // when we get here, the vdc_ method is actually the old, real method
}

- (void)vdc_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    UIViewController* controller = self.viewDeckController ? self.viewDeckController : self;
    [controller vdc_dismissViewControllerAnimated:flag completion:completion]; // when we get here, the vdc_ method is actually the old, real method
}

#endif

- (UINavigationController*)vdc_navigationController {
    UIViewController* controller = self.viewDeckController_core ? self.viewDeckController_core : self;
    return [controller vdc_navigationController]; // when we get here, the vdc_ method is actually the old, real method
}

- (UINavigationItem*)vdc_navigationItem {
    UIViewController* controller = self.viewDeckController_core ? self.viewDeckController_core : self;
    return [controller vdc_navigationItem]; // when we get here, the vdc_ method is actually the old, real method
}

+ (void)vdc_swizzle {
    SEL presentModal = @selector(presentModalViewController:animated:);
    SEL vdcPresentModal = @selector(vdc_presentModalViewController:animated:);
    method_exchangeImplementations(class_getInstanceMethod(self, presentModal), class_getInstanceMethod(self, vdcPresentModal));
    
    SEL presentVC = @selector(presentViewController:animated:completion:);
    SEL vdcPresentVC = @selector(vdc_presentViewController:animated:completion:);
    method_exchangeImplementations(class_getInstanceMethod(self, presentVC), class_getInstanceMethod(self, vdcPresentVC));
    
    SEL nc = @selector(navigationController);
    SEL vdcnc = @selector(vdc_navigationController);
    method_exchangeImplementations(class_getInstanceMethod(self, nc), class_getInstanceMethod(self, vdcnc));
    
    SEL ni = @selector(navigationItem);
    SEL vdcni = @selector(vdc_navigationItem);
    method_exchangeImplementations(class_getInstanceMethod(self, ni), class_getInstanceMethod(self, vdcni));
}

+ (void)load {
    [self vdc_swizzle];
    
#if 0
    [self swizzleLifecycleLogging];
#endif
}

#if 0
+ (void)swizzleLifecycleLogging{
    SEL viewWillAppear = @selector(viewWillAppear:);
    SEL viewDidAppear = @selector(viewDidAppear:);
    SEL viewWillDisappear = @selector(viewWillDisappear:);
    SEL viewDidDisappear = @selector(viewDidDisappear:);
    
    SEL test_viewWillAppear = @selector(test_viewWillAppear:);
    SEL test_viewDidAppear = @selector(test_viewDidAppear:);
    SEL test_viewWillDisappear = @selector(test_viewWillDisappear:);
    SEL test_viewDidDisappear = @selector(test_viewDidDisappear:);
    
    method_exchangeImplementations(class_getInstanceMethod(self, viewWillAppear), class_getInstanceMethod(self, test_viewWillAppear));
    method_exchangeImplementations(class_getInstanceMethod(self, viewDidAppear), class_getInstanceMethod(self, test_viewDidAppear));
    method_exchangeImplementations(class_getInstanceMethod(self, viewWillDisappear), class_getInstanceMethod(self, test_viewWillDisappear));
    method_exchangeImplementations(class_getInstanceMethod(self, viewDidDisappear), class_getInstanceMethod(self, test_viewDidDisappear));
}

#define LOG_METHOD NSLog(@"%@<%p> %@", self.class, self, NSStringFromSelector(_cmd))

- (void)test_viewWillAppear:(BOOL)animated{
    [self test_viewWillAppear:animated];
    LOG_METHOD;
}

- (void)test_viewDidAppear:(BOOL)animated{
    [self test_viewDidAppear:animated];
    LOG_METHOD;
}

- (void)test_viewWillDisappear:(BOOL)animated{
    [self test_viewWillDisappear:animated];
    LOG_METHOD;
}

- (void)test_viewDidDisappear:(BOOL)animated{
    [self test_viewDidDisappear:animated];
    LOG_METHOD;
}

#endif
@end
