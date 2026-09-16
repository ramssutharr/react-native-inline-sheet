#import <React/RCTViewComponentView.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Fabric view for a sheet slot (`sheet-body`, `sheet-footer`, `sheet-handle`).
/// Lays out and draws exactly like a `View`; see
/// `cpp/NativeBottomSheetSlotShadowNode.h` for why it exists.
@interface NativeBottomSheetSlot : RCTViewComponentView

/// Re-reports how far this slot sits from where Fabric laid it out inside
/// `host` (the sheet's hidden Fabric host, which native code never moves).
/// Cheap when nothing moved: the shadow tree is only touched on a change.
- (void)syncContentOriginWithHost:(UIView *)host;

@end

NS_ASSUME_NONNULL_END
