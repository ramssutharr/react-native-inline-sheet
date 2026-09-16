#pragma once

#include <react/renderer/components/RNBottomSheetNativeSpec/EventEmitters.h>
#include <react/renderer/components/RNBottomSheetNativeSpec/Props.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>

#include "NativeBottomSheetSlotState.h"

namespace facebook::react {

extern const char NativeBottomSheetSlotComponentName[];

/// A `View` in every respect that affects layout. It exists for `measure()`:
/// Fabric computes a node's page position from the shadow tree, adding each
/// ancestor's content origin offset on the way down (that is how a scrolled
/// ScrollView's children measure correctly). The native sheet moves this
/// slot's subtree somewhere JS never laid it out, so the slot reports that
/// displacement as its content origin — `Pressable` then measures its rect
/// where it is actually drawn, and a touch-move no longer "leaves" it.
class NativeBottomSheetSlotShadowNode final : public ConcreteViewShadowNode<
                                                  NativeBottomSheetSlotComponentName,
                                                  NativeBottomSheetSlotProps,
                                                  NativeBottomSheetSlotEventEmitter,
                                                  NativeBottomSheetSlotState> {
 public:
  using ConcreteViewShadowNode::ConcreteViewShadowNode;

  Point getContentOriginOffset(bool includeTransform) const override;
};

} // namespace facebook::react
