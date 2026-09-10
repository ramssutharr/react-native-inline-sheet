import React, {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  BackHandler,
  Platform,
  StyleSheet,
  useWindowDimensions,
  View,
  type ColorValue,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import NativeBottomSheetView, { Commands } from './NativeBottomSheetNativeComponent';
import {
  BottomSheetNativeActionsContext,
  BottomSheetNativeLayoutContext,
  type BottomSheetNativeActions,
  type BottomSheetNativeLayout,
} from './context';
import {
  estimateSheetHeight,
  serializeDetents,
  SHEET_BODY_ID,
  SHEET_FOOTER_ID,
  type Detent,
} from './detents';

export type DismissReason = 'drag' | 'backdrop' | 'back' | 'programmatic' | 'unmounted';

/**
 * The imperative surface — deliberately the same shape as gorhom's
 * `BottomSheetModal` ref, so a registry that hands out refs can swap the
 * implementation without touching call sites.
 */
export type BottomSheetNativeRef<T = any> = {
  /** Mount the content (with `data`), attach natively and spring in. */
  present: (data?: T) => void;
  dismiss: () => void;
  /** Alias of `dismiss` (gorhom's `close`). */
  close: () => void;
  snapToIndex: (index: number) => void;
  snapTo: (index: number) => void;
  expand: () => void;
  collapse: () => void;
  isPresented: () => boolean;
};

type RenderProp<T> = React.ReactNode | ((args: { data: T }) => React.ReactNode);

/** gorhom-style snap point: `'60%'`, a dp number, or `'CONTENT_HEIGHT'`. */
export type SnapPoint = number | string;

/** gorhom's `keyboardBehavior`; 'extend' / 'fillParent' expand to the top detent. */
export type KeyboardBehavior = 'interactive' | 'extend' | 'fillParent';

export type BottomSheetNativeProps<T = any> = {
  /**
   * Ascending detents: `'auto'`, a fraction in (0, 1] of the available
   * height, or dp. Default `['auto']`. Ignored when `snapPoints` is given.
   */
  detents?: ReadonlyArray<Detent> | string;
  initialDetent?: number;
  /** Safe-area top: the tallest detent never enters it (gorhom's `topInset`). */
  topInset?: number;
  /** Raise the sheet's resting bottom edge — e.g. above a tab bar (gorhom's `bottomInset`). */
  bottomInset?: number;
  dimmed?: boolean;
  dimOpacity?: number;
  cornerRadius?: number;
  grabber?: boolean;
  grabberAreaHeight?: number;
  backgroundColor?: ColorValue;
  grabberColor?: ColorValue;
  grabberWidth?: number;
  grabberHeight?: number;
  enablePanToDismiss?: boolean;
  dismissOnBackdropPress?: boolean;

  // ── gorhom-compatible names (each maps onto the prop above it) ──
  /** `['60%', 400, 'CONTENT_HEIGHT']` — takes precedence over `detents`. */
  snapPoints?: ReadonlyArray<SnapPoint>;
  /** Initial snap index (gorhom's `index`). */
  index?: number;
  /** Adds a `CONTENT_HEIGHT` detent (gorhom v5's dynamic sizing). */
  enableDynamicSizing?: boolean;
  /** Alias of `enablePanToDismiss`. */
  enablePanDownToClose?: boolean;
  /** `backgroundColor` and `borderTopLeftRadius` / `borderRadius` are honoured. */
  backgroundStyle?: StyleProp<ViewStyle>;
  /** `backgroundColor`, `width` and `height` are honoured. */
  handleIndicatorStyle?: StyleProp<ViewStyle>;
  /** `null` hides the native grabber (a custom component is not rendered natively yet). */
  handleComponent?: React.ComponentType<any> | null;
  backdropColor?: ColorValue;
  /** 0 disables the backdrop. */
  backdropOpacity?: number;
  keyboardBehavior?: KeyboardBehavior;
  /** Detent animation starting: (fromIndex, toIndex); -1 = closed. */
  onAnimate?: (fromIndex: number, toIndex: number) => void;
  keyboardMode?: 'lift-footer' | 'none';
  /** Spring to the top detent when the keyboard opens (default true). */
  expandOnKeyboard?: boolean;
  /** Dismiss the keyboard as soon as the sheet takes a drag (default true). */
  dismissKeyboardOnDrag?: boolean;
  hostStrategy?: 'outermost-screen' | 'nearest-screen';
  /** Pinned to the visible bottom, lifted over the keyboard natively. */
  footer?: RenderProp<T>;
  /** The body. A function receives the `present(data)` payload. */
  children?: RenderProp<T>;
  bodyStyle?: StyleProp<ViewStyle>;
  footerStyle?: StyleProp<ViewStyle>;
  onPresent?: () => void;
  onDismiss?: (reason: DismissReason) => void;
  /** Settled detent index; -1 on dismiss (gorhom's `onChange`). */
  onChange?: (index: number) => void;
  onDragStart?: () => void;
  onDragEnd?: () => void;
};

const DEFAULT_DETENTS: ReadonlyArray<Detent> = ['auto'];
const DEFAULT_GRABBER_AREA = 22;

/** gorhom snap point → detent. */
function snapPointToDetent(point: SnapPoint): Detent {
  if (typeof point === 'number') return point;
  const trimmed = point.trim();
  if (trimmed === 'CONTENT_HEIGHT' || trimmed === 'auto') return 'auto';
  if (trimmed.endsWith('%')) return Math.max(0.0001, Math.min(1, parseFloat(trimmed) / 100));
  const numeric = Number(trimmed);
  return Number.isFinite(numeric) ? numeric : 'auto';
}

function renderProp<T>(node: RenderProp<T> | undefined, data: T): React.ReactNode {
  if (typeof node === 'function') return node({ data });
  return node ?? null;
}

function BottomSheetNativeInner<T = any>(
  props: BottomSheetNativeProps<T>,
  ref: React.ForwardedRef<BottomSheetNativeRef<T>>,
) {
  const {
    detents = DEFAULT_DETENTS,
    topInset = 0,
    bottomInset = 0,
    cornerRadius: cornerRadiusProp,
    grabberAreaHeight = DEFAULT_GRABBER_AREA,
    backgroundColor: backgroundColorProp,
    grabberColor: grabberColorProp,
    grabberWidth: grabberWidthProp,
    grabberHeight: grabberHeightProp,
    dismissOnBackdropPress = true,
    keyboardMode = 'lift-footer',
    dismissKeyboardOnDrag = true,
    hostStrategy = 'outermost-screen',
    footer,
    children,
    bodyStyle,
    footerStyle,
    onPresent,
    onDismiss,
    onChange,
    onAnimate,
    onDragStart,
    onDragEnd,
    // gorhom-compatible
    snapPoints,
    index,
    enableDynamicSizing = false,
    enablePanDownToClose,
    backgroundStyle,
    handleIndicatorStyle,
    handleComponent,
    backdropColor,
    backdropOpacity,
    keyboardBehavior,
  } = props;

  // ── Resolve the gorhom-style names onto the native props ──
  const initialDetent = index ?? props.initialDetent ?? 0;
  const enablePanToDismiss = enablePanDownToClose ?? props.enablePanToDismiss ?? true;
  const flatBackground = StyleSheet.flatten(backgroundStyle) ?? {};
  const flatHandle = StyleSheet.flatten(handleIndicatorStyle) ?? {};
  const backgroundColor = backgroundColorProp ?? (flatBackground.backgroundColor as ColorValue | undefined);
  const cornerRadius =
    cornerRadiusProp ??
    (typeof flatBackground.borderTopLeftRadius === 'number'
      ? flatBackground.borderTopLeftRadius
      : typeof flatBackground.borderRadius === 'number'
        ? flatBackground.borderRadius
        : 24);
  const grabber = props.grabber ?? handleComponent !== null;
  const grabberColor = grabberColorProp ?? (flatHandle.backgroundColor as ColorValue | undefined);
  const grabberWidth =
    grabberWidthProp ?? (typeof flatHandle.width === 'number' ? flatHandle.width : 36);
  const grabberHeight =
    grabberHeightProp ?? (typeof flatHandle.height === 'number' ? flatHandle.height : 5);
  const dimOpacity = props.dimOpacity ?? backdropOpacity ?? 0.5;
  const dimmed = props.dimmed ?? dimOpacity > 0;
  const expandOnKeyboard =
    keyboardBehavior != null ? keyboardBehavior !== 'interactive' : (props.expandOnKeyboard ?? true);

  const nativeRef = useRef<React.ElementRef<typeof NativeBottomSheetView>>(null);
  const { width: windowWidth, height: windowHeight } = useWindowDimensions();

  const detentList = useMemo<ReadonlyArray<Detent>>(() => {
    let list: Detent[];
    if (snapPoints != null && snapPoints.length > 0) {
      list = snapPoints.map(snapPointToDetent);
    } else if (typeof detents === 'string') {
      list = detents.split(',').map(t => (t.trim() === 'auto' ? 'auto' : Number(t)));
    } else {
      list = [...detents];
    }
    if (enableDynamicSizing && !list.includes('auto')) list.push('auto');
    return list.length > 0 ? list : DEFAULT_DETENTS;
  }, [snapPoints, detents, enableDynamicSizing]);
  const detentSpec = useMemo(() => serializeDetents(detentList), [detentList]);
  const lastIndex = Math.max(0, detentList.length - 1);
  const grabberArea = grabber ? grabberAreaHeight : 0;

  const [presented, setPresented] = useState(false);
  const [data, setData] = useState<T | undefined>(undefined);
  // Bumped on every present() so a second call with identical data (or one
  // that lands during the slide-out) still dispatches the native command.
  const [presentSerial, setPresentSerial] = useState(0);
  // Before native has reported anything, size the body from a JS estimate so
  // the very first frame of the presentation is close; native corrects it
  // through onLayoutChange while the sheet is still springing in.
  const estimateBodyHeight = useCallback(
    (index: number): number | null => {
      const d = detentList[Math.min(index, lastIndex)] ?? 'auto';
      const sheet = estimateSheetHeight(d, windowHeight - topInset - bottomInset);
      return sheet == null ? null : Math.max(0, sheet - grabberArea);
    },
    [detentList, lastIndex, windowHeight, topInset, bottomInset, grabberArea],
  );
  // The body is sized for the TOP fixed detent (see maxBodyHeight in the spec).
  const estimateMaxBodyHeight = useCallback((): number | null => {
    let top: number | null = null;
    detentList.forEach(d => {
      const sheet = estimateSheetHeight(d, windowHeight - topInset - bottomInset);
      if (sheet != null && (top == null || sheet > top)) top = sheet;
    });
    return top == null ? null : Math.max(0, top - grabberArea);
  }, [detentList, windowHeight, topInset, bottomInset, grabberArea]);
  const [layout, setLayout] = useState<BottomSheetNativeLayout>(() => {
    const body = estimateBodyHeight(initialDetent);
    const maxBody = estimateMaxBodyHeight();
    return {
      index: -1,
      sheetHeight: 0,
      bodyHeight: body,
      maxBodyHeight: maxBody,
      bottomInset: body != null && maxBody != null ? Math.max(0, maxBody - body) : 0,
      footerHeight: 0,
      keyboardHeight: 0,
      isPresented: false,
    };
  });

  const presentedRef = useRef(false);
  const pendingPresentIndex = useRef<number | null>(null);
  /** Last index reported through `onChange` (settled). */
  const lastReportedIndex = useRef(-1);
  /** Index the sheet is currently heading to (for `onAnimate`). */
  const animatingToIndex = useRef(-1);

  // The children must be mounted BEFORE native presents (it re-parents them
  // into the sheet), so `present` sets state and the command is dispatched
  // from an effect once the commit has landed.
  useEffect(() => {
    if (!presented || pendingPresentIndex.current == null) return;
    const node = nativeRef.current;
    if (node == null) return;
    const index = pendingPresentIndex.current;
    pendingPresentIndex.current = null;
    Commands.present(node, index);
  }, [presented, presentSerial]);

  const present = useCallback(
    (next?: T) => {
      pendingPresentIndex.current = initialDetent;
      presentedRef.current = true;
      setData(next);
      setLayout(prev => {
        if (prev.index >= 0) return { ...prev, isPresented: true };
        const body = estimateBodyHeight(initialDetent);
        const maxBody = estimateMaxBodyHeight();
        return {
          ...prev,
          isPresented: true,
          bodyHeight: body,
          maxBodyHeight: maxBody,
          bottomInset: body != null && maxBody != null ? Math.max(0, maxBody - body) : 0,
        };
      });
      setPresented(true);
      setPresentSerial(n => n + 1);
    },
    [initialDetent, estimateBodyHeight, estimateMaxBodyHeight],
  );

  const dismiss = useCallback(() => {
    const node = nativeRef.current;
    if (!presentedRef.current || node == null) return;
    Commands.dismiss(node);
  }, []);

  // Android hardware/gesture back: React Native routes the legacy back press
  // through its own JS BackHandler and only falls through to the Activity's
  // OnBackPressedDispatcher (where the native sheet registers) if no JS
  // listener claims it — so claim it here while presented. The native
  // callback still serves the predictive-back path.
  useEffect(() => {
    if (Platform.OS !== 'android' || !presented) return;
    const subscription = BackHandler.addEventListener('hardwareBackPress', () => {
      if (!presentedRef.current) return false;
      dismiss();
      return true;
    });
    return () => subscription.remove();
  }, [presented, dismiss]);

  const snapToIndex = useCallback((index: number) => {
    const node = nativeRef.current;
    if (!presentedRef.current || node == null) return;
    Commands.snapTo(node, index);
  }, []);

  const expand = useCallback(() => snapToIndex(lastIndex), [snapToIndex, lastIndex]);
  const collapse = useCallback(() => snapToIndex(0), [snapToIndex]);

  useImperativeHandle(
    ref,
    () => ({
      present,
      dismiss,
      close: dismiss,
      snapToIndex,
      snapTo: snapToIndex,
      expand,
      collapse,
      isPresented: () => presentedRef.current,
    }),
    [present, dismiss, snapToIndex, expand, collapse],
  );

  const actions = useMemo<BottomSheetNativeActions>(
    () => ({ snapToIndex, expand, collapse, close: dismiss, dismiss }),
    [snapToIndex, expand, collapse, dismiss],
  );

  const handlePresent = useCallback(() => {
    onPresent?.();
  }, [onPresent]);

  const handleDismiss = useCallback(
    (e: { nativeEvent: { reason: string } }) => {
      presentedRef.current = false;
      pendingPresentIndex.current = null;
      setPresented(false);
      setLayout(prev => ({ ...prev, index: -1, isPresented: false, keyboardHeight: 0 }));
      if (animatingToIndex.current !== -1) {
        onAnimate?.(animatingToIndex.current, -1);
        animatingToIndex.current = -1;
      }
      if (lastReportedIndex.current !== -1) {
        lastReportedIndex.current = -1;
        onChange?.(-1);
      }
      onDismiss?.(e.nativeEvent.reason as DismissReason);
    },
    [onDismiss, onChange, onAnimate],
  );

  const handleLayoutChange = useCallback(
    (e: {
      nativeEvent: {
        index: number;
        sheetHeight: number;
        bodyHeight: number;
        maxBodyHeight: number;
        footerHeight: number;
        keyboardHeight: number;
        phase: number;
      };
    }) => {
      const { index, sheetHeight, bodyHeight, maxBodyHeight, footerHeight, keyboardHeight, phase } =
        e.nativeEvent;
      setLayout(prev => {
        const nextBody = bodyHeight < 0 ? null : bodyHeight;
        const nextMax = maxBodyHeight < 0 ? null : maxBodyHeight;
        const nextInset = nextBody != null && nextMax != null ? Math.max(0, nextMax - nextBody) : 0;
        if (
          prev.index === index &&
          prev.sheetHeight === sheetHeight &&
          prev.bodyHeight === nextBody &&
          prev.maxBodyHeight === nextMax &&
          prev.footerHeight === footerHeight &&
          prev.keyboardHeight === keyboardHeight &&
          prev.isPresented
        ) {
          return prev;
        }
        return {
          index,
          sheetHeight,
          bodyHeight: nextBody,
          maxBodyHeight: nextMax,
          bottomInset: nextInset,
          footerHeight,
          keyboardHeight,
          isPresented: true,
        };
      });
      // gorhom timing: `onAnimate(from, to)` when a detent animation starts,
      // `onChange(index)` once it has settled.
      if (phase === 0 && animatingToIndex.current !== index) {
        onAnimate?.(animatingToIndex.current === -1 ? lastReportedIndex.current : animatingToIndex.current, index);
        animatingToIndex.current = index;
      }
      if (phase === 1) {
        animatingToIndex.current = index;
        if (lastReportedIndex.current !== index) {
          lastReportedIndex.current = index;
          onChange?.(index);
        }
      }
    },
    [onChange, onAnimate],
  );

  const handleDragStart = useCallback(() => onDragStart?.(), [onDragStart]);
  const handleDragEnd = useCallback(() => onDragEnd?.(), [onDragEnd]);

  const bodyContent = presented ? renderProp(children, data as T) : null;
  const footerContent = presented && footer != null ? renderProp(footer, data as T) : null;

  return (
    <NativeBottomSheetView
      ref={nativeRef}
      style={styles.host}
      pointerEvents="none"
      detents={detentSpec}
      initialDetent={initialDetent}
      maxDetentInset={topInset}
      bottomInset={bottomInset}
      dimmed={dimmed}
      dimOpacity={dimOpacity}
      dimColor={backdropColor}
      cornerRadius={cornerRadius}
      grabber={grabber}
      grabberAreaHeight={grabberAreaHeight}
      sheetBackgroundColor={backgroundColor}
      grabberColor={grabberColor}
      grabberWidth={grabberWidth}
      grabberHeight={grabberHeight}
      enablePanToDismiss={enablePanToDismiss}
      dismissOnBackdropPress={dismissOnBackdropPress}
      keyboardMode={keyboardMode}
      expandOnKeyboard={expandOnKeyboard}
      dismissKeyboardOnDrag={dismissKeyboardOnDrag}
      hostStrategy={hostStrategy}
      onPresent={handlePresent}
      onDismiss={handleDismiss}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onLayoutChange={handleLayoutChange}
    >
      {presented ? (
        <BottomSheetNativeLayoutContext.Provider value={layout}>
          <BottomSheetNativeActionsContext.Provider value={actions}>
            <View
              nativeID={SHEET_BODY_ID}
              collapsable={false}
              style={[
                styles.child,
                { width: windowWidth },
                // Content-sized at an `auto` detent; otherwise the TOP fixed
                // detent's body so dragging up never uncovers bare sheet.
                layout.bodyHeight == null
                  ? null
                  : { height: layout.maxBodyHeight ?? layout.bodyHeight },
                bodyStyle,
              ]}
            >
              {bodyContent}
            </View>
            {footerContent != null ? (
              <View
                nativeID={SHEET_FOOTER_ID}
                collapsable={false}
                style={[styles.child, { width: windowWidth }, footerStyle]}
              >
                {footerContent}
              </View>
            ) : null}
          </BottomSheetNativeActionsContext.Provider>
        </BottomSheetNativeLayoutContext.Provider>
      ) : null}
    </NativeBottomSheetView>
  );
}

/**
 * A native bottom sheet whose content is ordinary React.
 *
 * Render it anywhere inside the screen that should own it — it keeps that
 * screen's React context (no portal, no teleport) and attaches natively to
 * the screen's own view, above a tab bar and below any stack push.
 */
export const BottomSheetNative = forwardRef(BottomSheetNativeInner) as <T = any>(
  props: BottomSheetNativeProps<T> & { ref?: React.Ref<BottomSheetNativeRef<T>> },
) => React.ReactElement | null;

/**
 * Spread onto the sheet's main list (FlatList / FlashList / ScrollView). On
 * Android the scroll↔sheet hand-off rides on nested scrolling, which RN's
 * ScrollView leaves OFF by default; iOS needs nothing.
 */
export const sheetScrollableProps =
  Platform.OS === 'android' ? ({ nestedScrollEnabled: true } as const) : ({} as const);

const styles = StyleSheet.create({
  // A parking lot, never visible: children are re-parented into the native
  // sheet on present. Zero-size + clipped so nothing paints here meanwhile.
  host: {
    position: 'absolute',
    top: 0,
    left: 0,
    width: 0,
    height: 0,
    overflow: 'hidden',
  },
  // Fabric positions each child relative to the host — as a column, the
  // footer would land BELOW the body (y = body height) and carry that offset
  // into its native slot. Absolute at the origin gives every child (0, 0);
  // an `auto` body still sizes to its content.
  child: {
    position: 'absolute',
    top: 0,
    left: 0,
  },
});
