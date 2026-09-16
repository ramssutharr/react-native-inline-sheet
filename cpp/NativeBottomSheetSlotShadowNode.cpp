#include "NativeBottomSheetSlotShadowNode.h"

namespace facebook::react {

extern const char NativeBottomSheetSlotComponentName[] = "NativeBottomSheetSlot";

Point NativeBottomSheetSlotShadowNode::getContentOriginOffset(bool /*includeTransform*/) const {
  return getStateData().contentOffset;
}

} // namespace facebook::react
