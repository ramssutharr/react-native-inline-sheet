#pragma once

#include <react/renderer/graphics/Point.h>

namespace facebook::react {

/// Where native code has really put a sheet slot, relative to where Fabric laid
/// it out. The slot's React subtree is re-parented into the native sheet, so
/// its on-screen position is invisible to the shadow tree; this is the
/// difference, supplied by the host view.
class NativeBottomSheetSlotState final {
 public:
  NativeBottomSheetSlotState() = default;
  explicit NativeBottomSheetSlotState(Point contentOffset) : contentOffset(contentOffset) {}

  Point contentOffset{};
};

} // namespace facebook::react
