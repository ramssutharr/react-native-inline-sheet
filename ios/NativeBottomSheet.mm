#import "NativeBottomSheet.h"

#import <react/renderer/components/RNBottomSheetNativeSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNBottomSheetNativeSpec/EventEmitters.h>
#import <react/renderer/components/RNBottomSheetNativeSpec/Props.h>
#import <react/renderer/components/RNBottomSheetNativeSpec/RCTComponentViewHelpers.h>

#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>
#import <React/RCTScrollViewComponentView.h>

// Forward-declared Swift surface (no Swift umbrella import: the Swift
// @objc(NativeBottomSheetContent) registers the class with the runtime, so
// this declaration links).
@interface NativeBottomSheetContent : UIView
- (void)setDetents:(NSString *)spec;
- (void)setInitialDetent:(NSInteger)index;
- (void)setMaxDetentInset:(CGFloat)inset;
- (void)setBottomInset:(CGFloat)inset;
- (void)setDimColor:(UIColor *_Nullable)color;
- (void)setGrabberWidth:(CGFloat)value;
- (void)setGrabberHeight:(CGFloat)value;
- (void)setDimmed:(BOOL)value;
- (void)setDimOpacity:(CGFloat)value;
- (void)setCornerRadius:(CGFloat)value;
- (void)setGrabber:(BOOL)value;
- (void)setGrabberAreaHeight:(CGFloat)value;
- (void)setSheetBackgroundColor:(UIColor *_Nullable)color;
- (void)setGrabberColor:(UIColor *_Nullable)color;
- (void)setEnablePanToDismiss:(BOOL)value;
- (void)setDismissOnBackdropPress:(BOOL)value;
- (void)setKeyboardMode:(NSString *)value;
- (void)setExpandOnKeyboard:(BOOL)value;
- (void)setDismissKeyboardOnDrag:(BOOL)value;
- (void)setHostStrategy:(NSString *)value;
- (void)mountChild:(UIView *)child nativeId:(NSString *_Nullable)nativeId;
- (void)unmountChild:(UIView *)child;
- (void)present:(NSInteger)index;
- (void)dismiss;
- (void)snapTo:(NSInteger)index;
- (void)reset;
@property (nonatomic, copy, nullable) void (^onPresent)(void);
@property (nonatomic, copy, nullable) void (^onDismiss)(NSString *reason);
@property (nonatomic, copy, nullable) void (^onDragStart)(void);
@property (nonatomic, copy, nullable) void (^onDragEnd)(void);
@property (nonatomic, copy, nullable) void (^onLayoutChange)
    (NSInteger index, CGFloat sheetHeight, CGFloat bodyHeight, CGFloat maxBodyHeight, CGFloat footerHeight,
     CGFloat keyboardHeight, NSInteger phase);
@property (nonatomic, copy, nullable) void (^cancelReactTouches)(void);
@property (nonatomic, copy, nullable) UIScrollView *_Nullable (^scrollViewResolver)(UIView *bodyRoot);
@end

using namespace facebook::react;

@interface NativeBottomSheet () <RCTNativeBottomSheetViewProtocol>
@end

@implementation NativeBottomSheet {
  NativeBottomSheetContent *_content;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<NativeBottomSheetComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const NativeBottomSheetProps>();
    _props = defaultProps;

    _content = [[NativeBottomSheetContent alloc] initWithFrame:self.bounds];
    _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_content];

    __weak NativeBottomSheet *weakSelf = self;
    _content.scrollViewResolver = ^UIScrollView *_Nullable(UIView *bodyRoot) {
      return [weakSelf resolveScrollViewIn:bodyRoot];
    };
    _content.cancelReactTouches = ^{
      [weakSelf cancelReactTouches];
    };
    _content.onPresent = ^{
      [weakSelf emitPresent];
    };
    _content.onDismiss = ^(NSString *reason) {
      [weakSelf emitDismiss:reason];
    };
    _content.onDragStart = ^{
      [weakSelf emitDragStart];
    };
    _content.onDragEnd = ^{
      [weakSelf emitDragEnd];
    };
    _content.onLayoutChange = ^(NSInteger index, CGFloat sheetHeight, CGFloat bodyHeight, CGFloat maxBodyHeight,
                                CGFloat footerHeight, CGFloat keyboardHeight, NSInteger phase) {
      [weakSelf emitLayoutChange:index
                     sheetHeight:sheetHeight
                      bodyHeight:bodyHeight
                   maxBodyHeight:maxBodyHeight
                    footerHeight:footerHeight
                  keyboardHeight:keyboardHeight
                           phase:phase];
    };
  }
  return self;
}

#pragma mark - React touch cancellation

/// React Native's `RCTSurfaceTouchHandler` (a gesture recognizer on the
/// surface view) keeps delivering the touch to JS while our pan moves the
/// sheet — a Pressable under the finger would fire on release. Toggling
/// `enabled` is what RN's own `_cancelTouches` does (and what
/// react-native-screens does for its back gesture).
- (void)cancelReactTouches
{
  Class handlerClass = NSClassFromString(@"RCTSurfaceTouchHandler");
  if (handlerClass == nil) {
    return;
  }
  UIView *view = self;
  while (view != nil) {
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
      if ([recognizer isKindOfClass:handlerClass]) {
        recognizer.enabled = NO;
        recognizer.enabled = YES;
        return;
      }
    }
    view = view.superview;
  }
}

#pragma mark - Scroll view discovery

/// Breadth-first so a nested vertical list inside a row never wins, and only
/// vertical lists: a horizontal RN ScrollView (an avatar carousel) also comes
/// through this class.
- (UIScrollView *_Nullable)resolveScrollViewIn:(UIView *)root
{
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
  NSUInteger visited = 0;
  while (queue.count > 0 && visited < 4000) {
    UIView *view = queue.firstObject;
    [queue removeObjectAtIndex:0];
    visited++;
    if ([view isKindOfClass:[RCTScrollViewComponentView class]]) {
      UIScrollView *scrollView = ((RCTScrollViewComponentView *)view).scrollView;
      if (scrollView.contentSize.height >= scrollView.contentSize.width || scrollView.alwaysBounceVertical) {
        return scrollView;
      }
    }
    [queue addObjectsFromArray:view.subviews];
  }
  return nil;
}

#pragma mark - RN children

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView index:(NSInteger)index
{
  NSString *nativeId = nil;
  if ([childComponentView respondsToSelector:@selector(nativeId)]) {
    nativeId = [(id)childComponentView nativeId];
  }
  [_content mountChild:childComponentView nativeId:nativeId];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView index:(NSInteger)index
{
  [_content unmountChild:childComponentView];
}

#pragma mark - Events

- (void)emitPresent
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::static_pointer_cast<const NativeBottomSheetEventEmitter>(_eventEmitter);
  emitter->onPresent({});
}

- (void)emitDismiss:(NSString *)reason
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::static_pointer_cast<const NativeBottomSheetEventEmitter>(_eventEmitter);
  emitter->onDismiss({.reason = std::string(reason.UTF8String ?: "")});
}

- (void)emitDragStart
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::static_pointer_cast<const NativeBottomSheetEventEmitter>(_eventEmitter);
  emitter->onDragStart({});
}

- (void)emitDragEnd
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::static_pointer_cast<const NativeBottomSheetEventEmitter>(_eventEmitter);
  emitter->onDragEnd({});
}

- (void)emitLayoutChange:(NSInteger)index
             sheetHeight:(CGFloat)sheetHeight
              bodyHeight:(CGFloat)bodyHeight
           maxBodyHeight:(CGFloat)maxBodyHeight
            footerHeight:(CGFloat)footerHeight
          keyboardHeight:(CGFloat)keyboardHeight
                   phase:(NSInteger)phase
{
  if (_eventEmitter == nullptr) {
    return;
  }
  auto emitter = std::static_pointer_cast<const NativeBottomSheetEventEmitter>(_eventEmitter);
  emitter->onLayoutChange({
      .index = static_cast<int>(index),
      .sheetHeight = static_cast<Float>(sheetHeight),
      .bodyHeight = static_cast<Float>(bodyHeight),
      .maxBodyHeight = static_cast<Float>(maxBodyHeight),
      .footerHeight = static_cast<Float>(footerHeight),
      .keyboardHeight = static_cast<Float>(keyboardHeight),
      .phase = static_cast<int>(phase),
  });
}

#pragma mark - Commands

- (void)handleCommand:(const NSString *)commandName args:(const NSArray *)args
{
  RCTNativeBottomSheetHandleCommand(self, commandName, args);
}

- (void)present:(NSInteger)index
{
  [_content present:index];
}

- (void)dismiss
{
  [_content dismiss];
}

- (void)snapTo:(NSInteger)index
{
  [_content snapTo:index];
}

#pragma mark - Props

- (void)updateProps:(const Props::Shared &)props oldProps:(const Props::Shared &)oldProps
{
  const auto &newProps = *std::static_pointer_cast<const NativeBottomSheetProps>(props);
  const auto &previousProps = oldProps == nullptr
      ? *std::static_pointer_cast<const NativeBottomSheetProps>(_props)
      : *std::static_pointer_cast<const NativeBottomSheetProps>(oldProps);

  // Chrome + geometry inputs first, detents last: a detent re-resolve while
  // presented reads the grabber area and inset.
  if (oldProps == nullptr || newProps.grabber != previousProps.grabber) {
    [_content setGrabber:newProps.grabber];
  }
  if (oldProps == nullptr || newProps.grabberAreaHeight != previousProps.grabberAreaHeight) {
    [_content setGrabberAreaHeight:newProps.grabberAreaHeight];
  }
  if (oldProps == nullptr || newProps.maxDetentInset != previousProps.maxDetentInset) {
    [_content setMaxDetentInset:newProps.maxDetentInset];
  }
  if (oldProps == nullptr || newProps.bottomInset != previousProps.bottomInset) {
    [_content setBottomInset:newProps.bottomInset];
  }
  if (oldProps == nullptr || newProps.dimColor != previousProps.dimColor) {
    [_content setDimColor:RCTUIColorFromSharedColor(newProps.dimColor)];
  }
  if (oldProps == nullptr || newProps.grabberWidth != previousProps.grabberWidth) {
    [_content setGrabberWidth:newProps.grabberWidth];
  }
  if (oldProps == nullptr || newProps.grabberHeight != previousProps.grabberHeight) {
    [_content setGrabberHeight:newProps.grabberHeight];
  }
  if (oldProps == nullptr || newProps.initialDetent != previousProps.initialDetent) {
    [_content setInitialDetent:newProps.initialDetent];
  }
  if (oldProps == nullptr || newProps.dimmed != previousProps.dimmed) {
    [_content setDimmed:newProps.dimmed];
  }
  if (oldProps == nullptr || newProps.dimOpacity != previousProps.dimOpacity) {
    [_content setDimOpacity:newProps.dimOpacity];
  }
  if (oldProps == nullptr || newProps.cornerRadius != previousProps.cornerRadius) {
    [_content setCornerRadius:newProps.cornerRadius];
  }
  if (oldProps == nullptr || newProps.sheetBackgroundColor != previousProps.sheetBackgroundColor) {
    [_content setSheetBackgroundColor:RCTUIColorFromSharedColor(newProps.sheetBackgroundColor)];
  }
  if (oldProps == nullptr || newProps.grabberColor != previousProps.grabberColor) {
    [_content setGrabberColor:RCTUIColorFromSharedColor(newProps.grabberColor)];
  }
  if (oldProps == nullptr || newProps.enablePanToDismiss != previousProps.enablePanToDismiss) {
    [_content setEnablePanToDismiss:newProps.enablePanToDismiss];
  }
  if (oldProps == nullptr || newProps.dismissOnBackdropPress != previousProps.dismissOnBackdropPress) {
    [_content setDismissOnBackdropPress:newProps.dismissOnBackdropPress];
  }
  if (oldProps == nullptr || newProps.keyboardMode != previousProps.keyboardMode) {
    [_content setKeyboardMode:[NSString stringWithUTF8String:newProps.keyboardMode.c_str()] ?: @"lift-footer"];
  }
  if (oldProps == nullptr || newProps.expandOnKeyboard != previousProps.expandOnKeyboard) {
    [_content setExpandOnKeyboard:newProps.expandOnKeyboard];
  }
  if (oldProps == nullptr || newProps.dismissKeyboardOnDrag != previousProps.dismissKeyboardOnDrag) {
    [_content setDismissKeyboardOnDrag:newProps.dismissKeyboardOnDrag];
  }
  if (oldProps == nullptr || newProps.hostStrategy != previousProps.hostStrategy) {
    [_content setHostStrategy:[NSString stringWithUTF8String:newProps.hostStrategy.c_str()] ?: @"outermost-screen"];
  }
  if (oldProps == nullptr || newProps.detents != previousProps.detents) {
    [_content setDetents:[NSString stringWithUTF8String:newProps.detents.c_str()] ?: @"auto"];
  }

  [super updateProps:props oldProps:oldProps];
}

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  [_content reset];
}

@end

Class<RCTComponentViewProtocol> NativeBottomSheetCls(void)
{
  return NativeBottomSheet.class;
}
