import type React from 'react';
import type { CodegenTypes, ColorValue, HostComponent, ViewProps } from 'react-native';
import { codegenNativeCommands, codegenNativeComponent } from 'react-native';

/**
 * The native sheet host.
 *
 * Native owns the FRAME: present/dismiss animation, drag, detent physics,
 * the dim backdrop, the scroll↔drag hand-off, lifting the footer over the
 * keyboard, the back gesture. React owns the CONTENT. Nothing on the JS
 * thread runs per frame.
 *
 * Inline mode: the sheet is attached to the hosting screen's own native view
 * (the outermost react-native-screens screen on the way up), so it sits
 * above a tab bar but BELOW anything the navigator pushes — a stack push
 * slides over the open sheet, and popping reveals it exactly as it was.
 * Modal mode (`hostStrategy: 'root'`) attaches to React Native's root surface
 * view instead, above every screen.
 *
 * React children are mounted by Fabric under this component and re-parented
 * natively into the sheet, identified by `nativeID`:
 *
 *   - `sheet-body`   → the scrollable content (required)
 *   - `sheet-footer` → pinned to the sheet's visible bottom, lifted over the
 *                      keyboard (optional)
 *   - `sheet-handle` → replaces the native grabber; its measured height is
 *                      the handle area (optional)
 *
 * The body is sized by JS: `width` = the host width, `height` = the current
 * settled detent's body height (`onLayoutChange` reports it — one round trip
 * per detent, never per frame). For an `auto` detent the body is left
 * content-sized and native reads its laid-out height.
 */

type LayoutChangeEvent = Readonly<{
  /** Settled detent index (into the detents SORTED by resolved height). */
  index: CodegenTypes.Int32;
  /** The sheet's visible height at this detent, dp. */
  sheetHeight: CodegenTypes.Float;
  /**
   * Height (dp) the `sheet-body` child should be given for this detent, or
   * -1 when the detent is `auto` (leave the body content-sized).
   */
  bodyHeight: CodegenTypes.Float;
  /**
   * Body height (dp) at the TOP non-`auto` detent, or -1 if every detent is
   * `auto`. JS sizes the body to this, not to the current detent, so a drag
   * past the current detent never reveals empty background; at lower
   * detents the part below the visible edge is simply clipped (lists pad
   * by `maxBodyHeight - bodyHeight` so their end stays reachable).
   */
  maxBodyHeight: CodegenTypes.Float;
  /** Measured height (dp) of the `sheet-footer` child (0 without one). */
  footerHeight: CodegenTypes.Float;
  /** How far (dp) the footer is currently lifted by the keyboard. */
  keyboardHeight: CodegenTypes.Float;
  /** The host layer's height (dp) — `hostHeight - sheetHeight` is gorhom's "position". */
  hostHeight: CodegenTypes.Float;
  /** 1 when the settled detent is an `auto` (content-sized) one, else 0. */
  dynamic: CodegenTypes.Int32;
  /** 1 = settled (animation finished), 0 = live (detent chosen, still moving). */
  phase: CodegenTypes.Int32;
}>;

type PositionChangeEvent = Readonly<{
  /**
   * Distance (dp) from the host layer's top edge to the sheet's top edge —
   * gorhom's `animatedPosition` (0 = flush with the top, host height = closed).
   */
  position: CodegenTypes.Float;
  /**
   * Fractional detent index — gorhom's `animatedIndex`: -1 closed, 0 at the
   * lowest detent, interpolated in between.
   */
  index: CodegenTypes.Float;
  /** The sheet's visible height (dp). */
  height: CodegenTypes.Float;
}>;

type DismissEvent = Readonly<{
  /** 'drag' | 'backdrop' | 'back' | 'programmatic' | 'unmounted' */
  reason: string;
}>;

// Codegen requires an empty event payload to be spelled exactly this way.
// eslint-disable-next-line @typescript-eslint/no-empty-object-type
type EmptyEvent = Readonly<{}>;

export interface NativeProps extends ViewProps {
  /**
   * Comma-joined detents. Each is `auto` (the body's own laid-out height), a
   * fraction in (0, 1] of the available height (host height minus
   * `maxDetentInset`), or a dp value > 1. e.g. "0.667,1", "auto", "320,1".
   * Native sorts them by RESOLVED height (an `auto` detent lands wherever the
   * content puts it — gorhom's dynamic sizing), and every index in this
   * contract refers to that sorted order. Arrays never travel over the
   * bridge here — same convention as the rest of the app's Fabric surfaces.
   */
  detents: string;
  /** Detent index the sheet presents at. */
  initialDetent?: CodegenTypes.WithDefault<CodegenTypes.Int32, 0>;
  /** Top inset (dp) the tallest detent never enters — pass the safe-area top. */
  maxDetentInset?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Raise the sheet's resting bottom edge by this much (dp) — e.g. above a tab bar. */
  bottomInset?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /**
   * The content's own bottom padding (dp) — its safe-area bottom, say. Not
   * applied while the keyboard is open: the sheet rises by the keyboard
   * height MINUS this, so that padding sits over the keyboard instead of
   * stacking on top of it.
   */
  contentBottomInset?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Cap (dp) on an `auto` detent's sheet height; 0 = the available height. */
  maxAutoHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Draw a dim backdrop that blocks touches to the screen beneath. */
  dimmed?: CodegenTypes.WithDefault<boolean, true>;
  dimOpacity?: CodegenTypes.WithDefault<CodegenTypes.Float, 0.5>;
  dimColor?: ColorValue;
  cornerRadius?: CodegenTypes.WithDefault<CodegenTypes.Float, 15>;
  /** Show the native grabber pill; the body starts below its area. */
  grabber?: CodegenTypes.WithDefault<boolean, true>;
  /** Height (dp) reserved above the body when `grabber` is on. */
  grabberAreaHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 24>;
  sheetBackgroundColor?: ColorValue;
  grabberColor?: ColorValue;
  grabberWidth?: CodegenTypes.WithDefault<CodegenTypes.Float, 30>;
  grabberHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 4>;
  /** Dragging below the lowest detent dismisses (else it rubber-bands). */
  enablePanToDismiss?: CodegenTypes.WithDefault<boolean, true>;
  dismissOnBackdropPress?: CodegenTypes.WithDefault<boolean, true>;
  /**
   * Whether a drag on the body moves the sheet (and the body's list is held
   * at offset 0 below the top detent). Off: only the handle area drags the
   * sheet and the list scrolls freely at every detent.
   */
  enableContentPanningGesture?: CodegenTypes.WithDefault<boolean, true>;
  /** Whether a drag on the handle area moves the sheet. */
  enableHandlePanningGesture?: CodegenTypes.WithDefault<boolean, true>;
  /**
   * Let a handle drag pull the sheet past its top detent with resistance
   * (gorhom's `enableOverDrag`, default on). Off: the top detent is a hard stop.
   */
  enableOverDrag?: CodegenTypes.WithDefault<boolean, true>;
  /** Divides the over-drag travel; larger = stiffer. */
  overDragResistanceFactor?: CodegenTypes.WithDefault<CodegenTypes.Float, 2.5>;
  /**
   * 'lift-sheet' (default — gorhom's `keyboardBehavior="interactive"`): the
   * WHOLE sheet rises by the keyboard height, as far as the top inset
   * allows; whatever it cannot rise, the footer slot rises on its own, so a
   * footer always clears the keyboard. 'lift-footer': only the footer slot
   * rises, the body is clipped behind it. 'none'.
   */
  keyboardMode?: CodegenTypes.WithDefault<string, 'lift-sheet'>;
  /** Spring to the top detent when the keyboard opens (Instagram's comments; gorhom's 'extend'). */
  expandOnKeyboard?: CodegenTypes.WithDefault<boolean, false>;
  /** Return to the detent the sheet was at before the keyboard opened, once it hides. */
  restoreDetentOnKeyboardHide?: CodegenTypes.WithDefault<boolean, false>;
  /** Dismiss the keyboard as soon as the sheet takes a drag (gorhom's `enableBlurKeyboardOnGesture`). */
  dismissKeyboardOnDrag?: CodegenTypes.WithDefault<boolean, false>;
  /**
   * Floating card: the sheet keeps `detachedMargin` from both side edges,
   * rounds all four corners and rests `bottomInset` above the bottom.
   */
  detached?: CodegenTypes.WithDefault<boolean, false>;
  detachedMargin?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /**
   * Which native view the sheet attaches to: 'outermost-screen' (default —
   * covers a tab bar, sits under every stack push), 'nearest-screen', or
   * 'root' (React Native's surface view: above every screen — modal mode).
   */
  hostStrategy?: CodegenTypes.WithDefault<string, 'outermost-screen'>;
  /**
   * Arms `onPositionChange`. That event is the one per-frame thing here, so
   * it is emitted only when something is listening.
   */
  positionEventsEnabled?: CodegenTypes.WithDefault<boolean, false>;

  onPresent?: CodegenTypes.DirectEventHandler<EmptyEvent>;
  onDismiss?: CodegenTypes.DirectEventHandler<DismissEvent>;
  onDragStart?: CodegenTypes.DirectEventHandler<EmptyEvent>;
  onDragEnd?: CodegenTypes.DirectEventHandler<EmptyEvent>;
  /**
   * Emitted when the sheet settles on a detent, when the footer's measured
   * height changes, and when the keyboard finishes moving. Never per frame.
   */
  onLayoutChange?: CodegenTypes.DirectEventHandler<LayoutChangeEvent>;
  /**
   * The sheet's live position, per frame while it moves (drag, spring,
   * keyboard), only while `positionEventsEnabled`. Intended for a Reanimated
   * `useEvent` worklet so content can track the sheet on the UI thread.
   */
  onPositionChange?: CodegenTypes.DirectEventHandler<PositionChangeEvent>;
}

type ComponentType = HostComponent<NativeProps>;

interface NativeCommands {
  /** Attach to the host and spring in to `index` (`animated` false = appear in place). */
  present: (viewRef: React.ElementRef<ComponentType>, index: CodegenTypes.Int32, animated: boolean) => void;
  /** Spring out; `onDismiss` fires with reason 'programmatic'. */
  dismiss: (viewRef: React.ElementRef<ComponentType>) => void;
  /** Animate to another detent while presented. */
  snapTo: (viewRef: React.ElementRef<ComponentType>, index: CodegenTypes.Int32) => void;
  /**
   * Animate to an arbitrary height while presented — the same token grammar
   * as one `detents` entry (`"0.5"`, `"320"`). gorhom's `snapToPosition`.
   */
  snapToHeight: (viewRef: React.ElementRef<ComponentType>, spec: string) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['present', 'dismiss', 'snapTo', 'snapToHeight'],
});

export default codegenNativeComponent<NativeProps>('NativeBottomSheet') as ComponentType;
