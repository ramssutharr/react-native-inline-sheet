import type { HostComponent, ViewProps } from 'react-native';
import { codegenNativeComponent } from 'react-native';

/**
 * A sheet slot (`sheet-body`, `sheet-footer`, `sheet-handle`) on iOS. Lays out
 * exactly like a `View`.
 *
 * It exists for touch handling. `Pressable` decides whether a moving finger is
 * still on it from `measure()`, which on Fabric reads the shadow tree — and
 * the shadow tree places a slot at the sheet's hidden host, not where the
 * native sheet draws it. Any press that emits a touch-move (a rolling finger,
 * or pressing harder on a 3D Touch iPhone) left that rect and never fired.
 * The slot's shadow node carries the real displacement, supplied natively, so
 * measured and drawn rects agree.
 *
 * Android's slots stay plain `View`s.
 */
export interface NativeProps extends ViewProps {}

export default codegenNativeComponent<NativeProps>('NativeBottomSheetSlot', {
  interfaceOnly: true,
  excludedPlatforms: ['android'],
}) as HostComponent<NativeProps>;
