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
 *
 * React children are mounted by Fabric under this component and re-parented
 * natively into the sheet, identified by `nativeID`:
 *
 *   - `sheet-body`   → the scrollable content (required)
 *   - `sheet-footer` → pinned to the sheet's visible bottom, lifted over the
 *                      keyboard (optional)
 *
 * The body is sized by JS: `width` = the host width, `height` = the current
 * settled detent's body height (`onLayoutChange` reports it — one round trip
 * per detent, never per frame). For an `auto` detent the body is left
 * content-sized and native reads its laid-out height.
 */

type LayoutChangeEvent = Readonly<{
  /** Settled detent index. */
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
  /** 1 = settled (animation finished), 0 = live (detent chosen, still moving). */
  phase: CodegenTypes.Int32;
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
   * Comma-joined detents in ASCENDING order. Each is `auto` (the body's own
   * laid-out height), a fraction in (0, 1] of the available height (host
   * height minus `maxDetentInset`), or a dp value > 1. e.g. "0.667,1",
   * "auto", "320,1". Arrays never travel over the bridge here — same
   * convention as the rest of the app's Fabric surfaces.
   */
  detents: string;
  /** Detent index the sheet presents at. */
  initialDetent?: CodegenTypes.WithDefault<CodegenTypes.Int32, 0>;
  /** Top inset (dp) the tallest detent never enters — pass the safe-area top. */
  maxDetentInset?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Raise the sheet's resting bottom edge by this much (dp) — e.g. above a tab bar. */
  bottomInset?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Draw a dim backdrop that blocks touches to the screen beneath. */
  dimmed?: CodegenTypes.WithDefault<boolean, true>;
  dimOpacity?: CodegenTypes.WithDefault<CodegenTypes.Float, 0.5>;
  dimColor?: ColorValue;
  cornerRadius?: CodegenTypes.WithDefault<CodegenTypes.Float, 24>;
  /** Show the native grabber pill; the body starts below its area. */
  grabber?: CodegenTypes.WithDefault<boolean, true>;
  /** Height (dp) reserved above the body when `grabber` is on. */
  grabberAreaHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 22>;
  sheetBackgroundColor?: ColorValue;
  grabberColor?: ColorValue;
  grabberWidth?: CodegenTypes.WithDefault<CodegenTypes.Float, 36>;
  grabberHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 5>;
  /** Dragging below the lowest detent dismisses (else it rubber-bands). */
  enablePanToDismiss?: CodegenTypes.WithDefault<boolean, true>;
  dismissOnBackdropPress?: CodegenTypes.WithDefault<boolean, true>;
  /** 'lift-footer' (default) | 'none'. */
  keyboardMode?: CodegenTypes.WithDefault<string, 'lift-footer'>;
  /** Spring to the top detent when the keyboard opens (Instagram's comments). */
  expandOnKeyboard?: CodegenTypes.WithDefault<boolean, true>;
  /** Dismiss the keyboard as soon as the sheet takes a drag. */
  dismissKeyboardOnDrag?: CodegenTypes.WithDefault<boolean, true>;
  /**
   * Which native screen the sheet attaches to: 'outermost-screen' (default —
   * covers a tab bar, sits under every stack push) or 'nearest-screen'.
   */
  hostStrategy?: CodegenTypes.WithDefault<string, 'outermost-screen'>;

  onPresent?: CodegenTypes.DirectEventHandler<EmptyEvent>;
  onDismiss?: CodegenTypes.DirectEventHandler<DismissEvent>;
  onDragStart?: CodegenTypes.DirectEventHandler<EmptyEvent>;
  onDragEnd?: CodegenTypes.DirectEventHandler<EmptyEvent>;
  /**
   * Emitted when the sheet settles on a detent, when the footer's measured
   * height changes, and when the keyboard finishes moving. Never per frame.
   */
  onLayoutChange?: CodegenTypes.DirectEventHandler<LayoutChangeEvent>;
}

type ComponentType = HostComponent<NativeProps>;

interface NativeCommands {
  /** Attach to the screen host and spring in to `index`. */
  present: (viewRef: React.ElementRef<ComponentType>, index: CodegenTypes.Int32) => void;
  /** Spring out; `onDismiss` fires with reason 'programmatic'. */
  dismiss: (viewRef: React.ElementRef<ComponentType>) => void;
  /** Animate to another detent while presented. */
  snapTo: (viewRef: React.ElementRef<ComponentType>, index: CodegenTypes.Int32) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['present', 'dismiss', 'snapTo'],
});

export default codegenNativeComponent<NativeProps>('NativeBottomSheet') as ComponentType;
