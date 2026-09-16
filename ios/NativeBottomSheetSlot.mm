#import "NativeBottomSheetSlot.h"

#import "NativeBottomSheetSlotComponentDescriptor.h"

#import <React/RCTConversions.h>
#import <React/RCTFabricComponentsPlugins.h>

using namespace facebook::react;

@implementation NativeBottomSheetSlot {
  NativeBottomSheetSlotShadowNode::ConcreteState::Shared _state;
  /// The offset the shadow tree holds (or is about to), so an unchanged
  /// position never commits a state update.
  CGPoint _reportedOffset;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<NativeBottomSheetSlotComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const NativeBottomSheetSlotProps>();
    _props = defaultProps;
  }
  return self;
}

- (void)updateState:(const State::Shared &)state oldState:(const State::Shared &)oldState
{
  _state = std::static_pointer_cast<const NativeBottomSheetSlotShadowNode::ConcreteState>(state);
  _reportedOffset = RCTCGPointFromPoint(_state->getData().contentOffset);
}

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  _state.reset();
  _reportedOffset = CGPointZero;
}

- (void)syncContentOriginWithHost:(UIView *)host
{
  if (_state == nullptr || self.window == nil || host.window != self.window) {
    return;
  }
  // Where Fabric believes the slot is: the host's position plus the slot's
  // laid-out origin inside it. Where it really is: wherever the sheet put it.
  // Both in window space — `measure()` pages are root-relative, and the root
  // only translates against the window, so the difference is the same.
  CGPoint host0 = [host convertPoint:CGPointZero toView:nil];
  CGPoint actual = [self convertPoint:CGPointZero toView:nil];
  CGPoint offset = CGPointMake(
      actual.x - (host0.x + _layoutMetrics.frame.origin.x), actual.y - (host0.y + _layoutMetrics.frame.origin.y));
  if (fabs(offset.x - _reportedOffset.x) < 0.5 && fabs(offset.y - _reportedOffset.y) < 0.5) {
    return;
  }
  _reportedOffset = offset;
  // Asynchronous is enough: the event queue flushes state updates before
  // events on every beat, so an offset pushed from hit-testing is in the tree
  // before JS handles the touch it belongs to.
  _state->updateState(NativeBottomSheetSlotState{RCTPointFromCGPoint(offset)});
}

@end

Class<RCTComponentViewProtocol> NativeBottomSheetSlotCls(void)
{
  return NativeBottomSheetSlot.class;
}
