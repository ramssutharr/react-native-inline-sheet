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
import { getReanimated, resolveHost, type SharedValueLike } from './animated';
import {
  BottomSheetNativeActionsContext,
  BottomSheetNativeAnimatedContext,
  BottomSheetNativeLayoutContext,
  type BottomSheetNativeActions,
  type BottomSheetNativeAnimated,
  type BottomSheetNativeLayout,
} from './context';
import {
  estimateSheetHeight,
  serializeDetents,
  SHEET_BODY_ID,
  SHEET_FOOTER_ID,
  SHEET_HANDLE_ID,
  type Detent,
} from './detents';
import { sheetStack, type StackBehavior, type StackEntry } from './stack';

export type DismissReason = 'drag' | 'backdrop' | 'back' | 'programmatic' | 'dismissed' | 'unmounted';

/** gorhom's third `onChange` argument. */
export enum SNAP_POINT_TYPE {
  PROVIDED = 0,
  DYNAMIC = 1,
}

/** 'inline' (default): in the screen's own layer, under stack pushes. 'modal': above every screen. */
export type SheetMode = 'inline' | 'modal';

/**
 * The imperative surface — deliberately the same shape as gorhom's
 * `BottomSheetModal` ref, so a registry that hands out refs can swap the
 * implementation without touching call sites.
 */
export type BottomSheetNativeRef<T = any> = {
  /** Mount the content (with `data`), attach natively and spring in. */
  present: (data?: T, options?: { animated?: boolean }) => void;
  dismiss: () => void;
  /** Alias of `dismiss` (gorhom's `close`). */
  close: () => void;
  /** Alias of `dismiss` (gorhom's `forceClose`). */
  forceClose: () => void;
  snapToIndex: (index: number) => void;
  snapTo: (index: number) => void;
  /** gorhom's `snapToPosition`: a dp number or a `'50%'` string. */
  snapToPosition: (position: number | string) => void;
  expand: () => void;
  collapse: () => void;
  isPresented: () => boolean;
  /** Slide out keeping the content mounted (what `stackBehavior="switch"` does to the sheet below). */
  minimize: () => void;
  restore: () => void;
};

type RenderProp<T> = React.ReactNode | ((args: { data: T }) => React.ReactNode);

/** gorhom-style snap point: `'60%'`, a dp number, or `'CONTENT_HEIGHT'`. */
export type SnapPoint = number | string;

/** gorhom's `keyboardBehavior`; 'extend' / 'fillParent' expand to the top detent. */
export type KeyboardBehavior = 'interactive' | 'extend' | 'fillParent';

export type HandleComponentProps = {
  animatedIndex: SharedValueLike<number>;
  animatedPosition: SharedValueLike<number>;
};

export type BottomSheetNativeProps<T = any> = {
  /**
   * Detents: `'auto'`, a fraction in (0, 1] of the available height, or dp.
   * Default `['auto']`. Ignored when `snapPoints` is given. Native sorts them
   * by resolved height; every index refers to that order.
   */
  detents?: ReadonlyArray<Detent> | string;
  initialDetent?: number;
  /** Safe-area top: the tallest detent never enters it (gorhom's `topInset`). */
  topInset?: number;
  /** Raise the sheet's resting bottom edge — e.g. above a tab bar (gorhom's `bottomInset`). */
  bottomInset?: number;
  /**
   * The content's own bottom padding — pass the safe-area bottom you pad
   * with. Not applied while the keyboard is open: the sheet rises by the
   * keyboard height minus this, so the padding sits over the keyboard.
   */
  contentBottomInset?: number;
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
  /** 'inline' (default) or 'modal' (above every screen, like a FullWindowOverlay). */
  mode?: SheetMode;

  // ── gorhom-compatible names (each maps onto the prop above it) ──
  /** `['60%', 400, 'CONTENT_HEIGHT']` — takes precedence over `detents`. */
  snapPoints?: ReadonlyArray<SnapPoint>;
  /** Initial snap index (gorhom's `index`). */
  index?: number;
  /** Adds a `CONTENT_HEIGHT` detent (gorhom v5's dynamic sizing). Default true, as gorhom's. */
  enableDynamicSizing?: boolean;
  /** Cap on the content-sized detent (gorhom's `maxDynamicContentSize`). */
  maxDynamicContentSize?: number;
  /** Alias of `enablePanToDismiss`. */
  enablePanDownToClose?: boolean;
  /** Off: only the handle drags the sheet and the list scrolls freely at every detent. */
  enableContentPanningGesture?: boolean;
  enableHandlePanningGesture?: boolean;
  /** Pull past the top detent with resistance (default true, as gorhom's; off = a hard stop). */
  enableOverDrag?: boolean;
  overDragResistanceFactor?: number;
  /** `backgroundColor` and `borderTopLeftRadius` / `borderRadius` are honoured. */
  backgroundStyle?: StyleProp<ViewStyle>;
  /** `backgroundColor`, `width` and `height` are honoured. */
  handleIndicatorStyle?: StyleProp<ViewStyle>;
  /**
   * `null` hides the native grabber. A component replaces it: rendered
   * natively in the handle slot and given `animatedIndex` / `animatedPosition`.
   */
  handleComponent?: React.ComponentType<HandleComponentProps> | null;
  /**
   * Accepted for drop-in compatibility but NOT rendered: the backdrop is
   * native. Use `backdropColor` / `backdropOpacity` / `dismissOnBackdropPress`.
   */
  backdropComponent?: React.ComponentType<any> | null;
  /** Accepted for drop-in compatibility; passing one switches to `mode="modal"`. */
  containerComponent?: React.ComponentType<any>;
  backdropColor?: ColorValue;
  /** 0 disables the backdrop. */
  backdropOpacity?: number;
  keyboardBehavior?: KeyboardBehavior;
  /** 'restore': return to the pre-keyboard detent once the keyboard hides. */
  keyboardBlurBehavior?: 'none' | 'restore';
  /** Floating card with `style` side margins (or `detachedMargin`) and all corners rounded. */
  detached?: boolean;
  detachedMargin?: number;
  /** Only `marginHorizontal` / `marginLeft` are read (for `detached`). */
  style?: StyleProp<ViewStyle>;
  /** gorhom's modal stacking: what presenting this sheet does to the one on top. Default 'switch'. */
  stackBehavior?: StackBehavior;
  /** Key for `useBottomSheetModal().dismiss(name)`. */
  name?: string;
  /** Present at `index` as soon as the sheet mounts (gorhom's non-modal `BottomSheet`). */
  presentOnMount?: boolean;
  /** With `presentOnMount`: animate in (default) or appear in place. */
  animateOnMount?: boolean;
  /** gorhom's shared values, written on the UI thread per frame while the sheet moves. */
  animatedIndex?: SharedValueLike<number>;
  animatedPosition?: SharedValueLike<number>;
  /** Detent animation starting: (fromIndex, toIndex, fromPosition, toPosition); -1 = closed. */
  onAnimate?: (fromIndex: number, toIndex: number, fromPosition: number, toPosition: number) => void;
  keyboardMode?: 'lift-footer' | 'lift-sheet' | 'none';
  /** Spring to the top detent when the keyboard opens (default false; `keyboardBehavior="extend"`). */
  expandOnKeyboard?: boolean;
  /** Dismiss the keyboard as soon as the sheet takes a drag (default false; gorhom's `enableBlurKeyboardOnGesture`). */
  dismissKeyboardOnDrag?: boolean;
  /** Alias of `dismissKeyboardOnDrag` (gorhom's name). */
  enableBlurKeyboardOnGesture?: boolean;
  hostStrategy?: 'outermost-screen' | 'nearest-screen' | 'root';
  /** Pinned to the visible bottom, lifted over the keyboard natively. */
  footer?: RenderProp<T>;
  /** The body. A function receives the `present(data)` payload. */
  children?: RenderProp<T>;
  bodyStyle?: StyleProp<ViewStyle>;
  footerStyle?: StyleProp<ViewStyle>;
  onPresent?: () => void;
  onDismiss?: (reason: DismissReason) => void;
  /** Alias of `onDismiss` (gorhom's non-modal `onClose`). */
  onClose?: () => void;
  /** Settled detent index (-1 on dismiss), its position (dp from the top) and whether it is content-sized. */
  onChange?: (index: number, position: number, type: SNAP_POINT_TYPE) => void;
  onDragStart?: () => void;
  onDragEnd?: () => void;
};

const DEFAULT_DETENTS: ReadonlyArray<Detent> = ['auto'];
const DEFAULT_GRABBER_AREA = 24;
let nameCounter = 0;

/** gorhom snap point → detent. */
function snapPointToDetent(point: SnapPoint): Detent {
  if (typeof point === 'number') return point;
  const trimmed = point.trim();
  if (trimmed === 'CONTENT_HEIGHT' || trimmed === 'auto') return 'auto';
  if (trimmed.endsWith('%')) return Math.max(0.0001, Math.min(1, parseFloat(trimmed) / 100));
  const numeric = Number(trimmed);
  return Number.isFinite(numeric) ? numeric : 'auto';
}

/** gorhom `snapToPosition` argument → native `snapToHeight` token. */
function positionToSpec(position: number | string): string | null {
  if (typeof position === 'number') return position > 0 ? String(position) : null;
  const trimmed = position.trim();
  if (trimmed.endsWith('%')) {
    const fraction = parseFloat(trimmed) / 100;
    return fraction > 0 ? String(Math.min(1, fraction)) : null;
  }
  const numeric = Number(trimmed);
  return Number.isFinite(numeric) && numeric > 0 ? String(numeric) : null;
}

function renderProp<T>(node: RenderProp<T> | undefined, data: T): React.ReactNode {
  if (typeof node === 'function') return node({ data });
  return node ?? null;
}

type LayoutEvent = {
  nativeEvent: {
    index: number;
    sheetHeight: number;
    bodyHeight: number;
    maxBodyHeight: number;
    footerHeight: number;
    keyboardHeight: number;
    hostHeight: number;
    dynamic: number;
    phase: number;
  };
};

function BottomSheetNativeInner<T = any>(
  props: BottomSheetNativeProps<T>,
  ref: React.ForwardedRef<BottomSheetNativeRef<T>>,
) {
  const {
    detents = DEFAULT_DETENTS,
    topInset = 0,
    bottomInset = 0,
    contentBottomInset = 0,
    cornerRadius: cornerRadiusProp,
    grabberAreaHeight = DEFAULT_GRABBER_AREA,
    backgroundColor: backgroundColorProp,
    grabberColor: grabberColorProp,
    grabberWidth: grabberWidthProp,
    grabberHeight: grabberHeightProp,
    dismissOnBackdropPress = true,
    dismissKeyboardOnDrag = false,
    mode,
    footer,
    children,
    bodyStyle,
    footerStyle,
    onPresent,
    onDismiss,
    onClose,
    onChange,
    onAnimate,
    onDragStart,
    onDragEnd,
    // gorhom-compatible
    snapPoints,
    index,
    enableDynamicSizing = true,
    maxDynamicContentSize,
    enablePanDownToClose,
    enableContentPanningGesture = true,
    enableHandlePanningGesture = true,
    enableOverDrag = true,
    overDragResistanceFactor = 2.5,
    backgroundStyle,
    handleIndicatorStyle,
    handleComponent,
    containerComponent,
    backdropColor,
    backdropOpacity,
    keyboardBehavior,
    keyboardBlurBehavior,
    detached = false,
    detachedMargin: detachedMarginProp,
    style,
    stackBehavior = 'switch',
    name,
    presentOnMount = false,
    animateOnMount = true,
    animatedIndex: animatedIndexProp,
    animatedPosition: animatedPositionProp,
  } = props;

  // ── Resolve the gorhom-style names onto the native props ──
  const initialDetent = index ?? props.initialDetent ?? 0;
  const enablePanToDismiss = enablePanDownToClose ?? props.enablePanToDismiss ?? true;
  const flatBackground = StyleSheet.flatten(backgroundStyle) ?? {};
  const flatHandle = StyleSheet.flatten(handleIndicatorStyle) ?? {};
  const flatStyle = StyleSheet.flatten(style) ?? {};
  const backgroundColor = backgroundColorProp ?? (flatBackground.backgroundColor as ColorValue | undefined);
  const cornerRadius =
    cornerRadiusProp ??
    (typeof flatBackground.borderTopLeftRadius === 'number'
      ? flatBackground.borderTopLeftRadius
      : typeof flatBackground.borderRadius === 'number'
        ? flatBackground.borderRadius
        : 15);
  const CustomHandle = typeof handleComponent === 'function' ? handleComponent : null;
  const grabber = props.grabber ?? handleComponent !== null;
  const grabberColor = grabberColorProp ?? (flatHandle.backgroundColor as ColorValue | undefined);
  const { width: windowWidth, height: windowHeight } = useWindowDimensions();
  // gorhom's default indicator: 7.5% of the window wide, 4 high.
  const grabberWidth =
    grabberWidthProp ?? (typeof flatHandle.width === 'number' ? flatHandle.width : (7.5 * windowWidth) / 100);
  const grabberHeight =
    grabberHeightProp ?? (typeof flatHandle.height === 'number' ? flatHandle.height : 4);
  const dimOpacity = props.dimOpacity ?? backdropOpacity ?? 0.5;
  const dimmed = props.dimmed ?? dimOpacity > 0;
  // gorhom: 'interactive' (its default) moves the whole sheet with the
  // keyboard; 'extend' / 'fillParent' expand to the top detent and the
  // footer lifts on its own.
  const expandOnKeyboard =
    keyboardBehavior != null ? keyboardBehavior !== 'interactive' : (props.expandOnKeyboard ?? false);
  const keyboardMode =
    props.keyboardMode ??
    (keyboardBehavior == null || keyboardBehavior === 'interactive' ? 'lift-sheet' : 'lift-footer');
  const restoreDetentOnKeyboardHide = keyboardBlurBehavior === 'restore';
  const detachedMargin =
    detachedMarginProp ??
    (typeof flatStyle.marginHorizontal === 'number'
      ? flatStyle.marginHorizontal
      : typeof flatStyle.marginLeft === 'number'
        ? flatStyle.marginLeft
        : 0);
  const hostStrategy =
    mode === 'modal' || containerComponent != null ? 'root' : (props.hostStrategy ?? 'outermost-screen');

  const nativeRef = useRef<React.ElementRef<typeof NativeBottomSheetView>>(null);

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
      const sorted = [...detentList].sort((a, b) => {
        const ha = estimateSheetHeight(a, windowHeight - topInset - bottomInset) ?? 0;
        const hb = estimateSheetHeight(b, windowHeight - topInset - bottomInset) ?? 0;
        return ha - hb;
      });
      const d = sorted[Math.min(index, lastIndex)] ?? 'auto';
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
      hostHeight: windowHeight,
      isPresented: false,
    };
  });

  const presentedRef = useRef(false);
  /** Slid out by `stackBehavior="switch"`, content still mounted. */
  const minimizedRef = useRef(false);
  const minimizedAtIndex = useRef(initialDetent);
  const pendingPresentIndex = useRef<number | null>(null);
  const pendingPresentAnimated = useRef(true);
  /** Last index reported through `onChange` (settled). */
  const lastReportedIndex = useRef(-1);
  /** Index the sheet is currently heading to (for `onAnimate`). */
  const animatingToIndex = useRef(-1);
  /** Sheet height per detent index, as native reported it (for `onChange` / `onAnimate` positions). */
  const detentHeights = useRef(new Map<number, number>());
  const hostHeightRef = useRef(windowHeight);

  // ── Reanimated bridge (optional peer; availability is constant per app) ──
  const reanimated = getReanimated();
  /* eslint-disable react-hooks/rules-of-hooks -- `reanimated` never changes for the app's lifetime */
  const internalIndex = reanimated != null ? reanimated.useSharedValue(-1) : null;
  const internalPosition = reanimated != null ? reanimated.useSharedValue(0) : null;
  const externalKey = useRef<unknown[]>([]);
  const externals = [animatedIndexProp, animatedPositionProp];
  const rebuild =
    externalKey.current.length !== externals.length || externals.some((v, i) => v !== externalKey.current[i]);
  externalKey.current = externals;
  const positionHandler =
    reanimated != null
      ? reanimated.useEvent(
          (event: { position: number; index: number }) => {
            'worklet';
            if (internalIndex != null) internalIndex.value = event.index;
            if (internalPosition != null) internalPosition.value = event.position;
            if (animatedIndexProp != null) animatedIndexProp.value = event.index;
            if (animatedPositionProp != null) animatedPositionProp.value = event.position;
          },
          ['onPositionChange'],
          rebuild,
        )
      : undefined;
  /* eslint-enable react-hooks/rules-of-hooks */
  // Without Reanimated the values still exist, updated when the sheet settles.
  const fallbackIndex = useRef<SharedValueLike<number>>({ value: -1 });
  const fallbackPosition = useRef<SharedValueLike<number>>({ value: 0 });
  const [animatedSubscribers, setAnimatedSubscribers] = useState(0);
  const subscribeAnimated = useCallback(() => {
    setAnimatedSubscribers(n => n + 1);
    return () => setAnimatedSubscribers(n => Math.max(0, n - 1));
  }, []);
  const positionEventsEnabled =
    reanimated != null && (animatedIndexProp != null || animatedPositionProp != null || animatedSubscribers > 0);
  const animatedValue = useMemo<BottomSheetNativeAnimated>(
    () => ({
      animatedIndex: animatedIndexProp ?? internalIndex ?? fallbackIndex.current,
      animatedPosition: animatedPositionProp ?? internalPosition ?? fallbackPosition.current,
      subscribe: subscribeAnimated,
    }),
    [animatedIndexProp, animatedPositionProp, internalIndex, internalPosition, subscribeAnimated],
  );

  // The children must be mounted BEFORE native presents (it re-parents them
  // into the sheet), so `present` sets state and the command is dispatched
  // from an effect once the commit has landed.
  useEffect(() => {
    if (!presented || pendingPresentIndex.current == null) return;
    const node = nativeRef.current;
    if (node == null) return;
    const index = pendingPresentIndex.current;
    pendingPresentIndex.current = null;
    Commands.present(node, index, pendingPresentAnimated.current);
  }, [presented, presentSerial]);

  // ── The modal stack (gorhom's stackBehavior) ──
  const latest = useRef({ minimize: () => {}, restore: () => {}, dismiss: () => {} });
  const entryRef = useRef<StackEntry | null>(null);
  if (entryRef.current == null) {
    entryRef.current = {
      name: name ?? `inline-sheet-${++nameCounter}`,
      minimize: () => latest.current.minimize(),
      restore: () => latest.current.restore(),
      dismiss: () => latest.current.dismiss(),
      isMinimized: () => minimizedRef.current,
    };
  }
  if (name != null) entryRef.current.name = name;
  const entry = entryRef.current;
  const stackBehaviorRef = useRef(stackBehavior);
  stackBehaviorRef.current = stackBehavior;

  const present = useCallback(
    (next?: T, options?: { animated?: boolean }) => {
      sheetStack.willPresent(entry, stackBehaviorRef.current);
      minimizedRef.current = false;
      pendingPresentIndex.current = initialDetent;
      pendingPresentAnimated.current = options?.animated ?? true;
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
    [entry, initialDetent, estimateBodyHeight, estimateMaxBodyHeight],
  );

  const positionOf = useCallback(
    (index: number): number => {
      const host = hostHeightRef.current;
      if (index < 0) return host;
      const known = detentHeights.current.get(index);
      if (known != null) return Math.max(0, host - bottomInset - known);
      const estimated = estimateBodyHeight(index);
      return estimated == null ? host : Math.max(0, host - bottomInset - estimated - grabberArea);
    },
    [bottomInset, estimateBodyHeight, grabberArea],
  );

  /** The sheet is gone for good: unmount the content and tell everyone. */
  const finalizeDismiss = useCallback(
    (reason: DismissReason) => {
      presentedRef.current = false;
      minimizedRef.current = false;
      pendingPresentIndex.current = null;
      setPresented(false);
      setLayout(prev => ({ ...prev, index: -1, isPresented: false, keyboardHeight: 0 }));
      if (animatingToIndex.current !== -1) {
        onAnimate?.(animatingToIndex.current, -1, positionOf(animatingToIndex.current), positionOf(-1));
        animatingToIndex.current = -1;
      }
      if (lastReportedIndex.current !== -1) {
        lastReportedIndex.current = -1;
        fallbackIndex.current.value = -1;
        fallbackPosition.current.value = positionOf(-1);
        onChange?.(-1, positionOf(-1), SNAP_POINT_TYPE.PROVIDED);
      }
      onDismiss?.(reason);
      onClose?.();
      sheetStack.didDismiss(entry);
    },
    [entry, onDismiss, onClose, onChange, onAnimate, positionOf],
  );

  const dismiss = useCallback(() => {
    if (minimizedRef.current) {
      // Already slid out: nothing native to animate, just let go of the content.
      finalizeDismiss('programmatic');
      return;
    }
    const node = nativeRef.current;
    if (!presentedRef.current || node == null) return;
    Commands.dismiss(node);
  }, [finalizeDismiss]);

  const minimize = useCallback(() => {
    const node = nativeRef.current;
    if (!presentedRef.current || minimizedRef.current || node == null) return;
    minimizedRef.current = true;
    minimizedAtIndex.current = lastReportedIndex.current >= 0 ? lastReportedIndex.current : initialDetent;
    Commands.dismiss(node);
  }, [initialDetent]);

  const restore = useCallback(() => {
    if (!minimizedRef.current) return;
    minimizedRef.current = false;
    presentedRef.current = true;
    pendingPresentIndex.current = minimizedAtIndex.current;
    pendingPresentAnimated.current = true;
    setLayout(prev => ({ ...prev, isPresented: true }));
    setPresentSerial(n => n + 1);
  }, []);

  latest.current = { minimize, restore, dismiss };

  // Unmounted with the sheet up (the hosting screen was popped): leave the
  // stack cleanly so a sheet this one had minimised comes back.
  useEffect(() => () => sheetStack.didDismiss(entry), [entry]);

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

  const snapToPosition = useCallback((position: number | string) => {
    const node = nativeRef.current;
    const spec = positionToSpec(position);
    if (!presentedRef.current || node == null || spec == null) return;
    Commands.snapToHeight(node, spec);
  }, []);

  const expand = useCallback(() => snapToIndex(lastIndex), [snapToIndex, lastIndex]);
  const collapse = useCallback(() => snapToIndex(0), [snapToIndex]);

  // gorhom's non-modal `BottomSheet`: on screen from the start.
  const presentOnMountRef = useRef({ presentOnMount, animateOnMount });
  useEffect(() => {
    const { presentOnMount: auto, animateOnMount: animated } = presentOnMountRef.current;
    if (auto) present(undefined, { animated });
  }, [present]);

  useImperativeHandle(
    ref,
    () => ({
      present,
      dismiss,
      close: dismiss,
      forceClose: dismiss,
      snapToIndex,
      snapTo: snapToIndex,
      snapToPosition,
      expand,
      collapse,
      isPresented: () => presentedRef.current,
      minimize,
      restore,
    }),
    [present, dismiss, snapToIndex, snapToPosition, expand, collapse, minimize, restore],
  );

  const actions = useMemo<BottomSheetNativeActions>(
    () => ({ snapToIndex, snapToPosition, expand, collapse, close: dismiss, forceClose: dismiss, dismiss }),
    [snapToIndex, snapToPosition, expand, collapse, dismiss],
  );

  const handlePresent = useCallback(() => {
    onPresent?.();
  }, [onPresent]);

  const handleDismiss = useCallback(
    (e: { nativeEvent: { reason: string } }) => {
      const reason = e.nativeEvent.reason as DismissReason;
      if (minimizedRef.current && reason !== 'unmounted') {
        // Slid out by the stack: the content stays mounted for the restore.
        presentedRef.current = false;
        pendingPresentIndex.current = null;
        setLayout(prev => ({ ...prev, index: -1, isPresented: false, keyboardHeight: 0 }));
        if (animatingToIndex.current !== -1) {
          onAnimate?.(animatingToIndex.current, -1, positionOf(animatingToIndex.current), positionOf(-1));
          animatingToIndex.current = -1;
        }
        if (lastReportedIndex.current !== -1) {
          lastReportedIndex.current = -1;
          fallbackIndex.current.value = -1;
          fallbackPosition.current.value = positionOf(-1);
          onChange?.(-1, positionOf(-1), SNAP_POINT_TYPE.PROVIDED);
        }
        return;
      }
      finalizeDismiss(reason);
    },
    [finalizeDismiss, onChange, onAnimate, positionOf],
  );

  const handleLayoutChange = useCallback(
    (e: LayoutEvent) => {
      const {
        index,
        sheetHeight,
        bodyHeight,
        maxBodyHeight,
        footerHeight,
        keyboardHeight,
        hostHeight,
        dynamic,
        phase,
      } = e.nativeEvent;
      hostHeightRef.current = hostHeight;
      detentHeights.current.set(index, sheetHeight);
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
          prev.hostHeight === hostHeight &&
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
          hostHeight,
          isPresented: true,
        };
      });
      const type = dynamic === 1 ? SNAP_POINT_TYPE.DYNAMIC : SNAP_POINT_TYPE.PROVIDED;
      const position = Math.max(0, hostHeight - bottomInset - sheetHeight);
      // gorhom timing: `onAnimate(from, to)` when a detent animation starts,
      // `onChange(index)` once it has settled.
      if (phase === 0 && animatingToIndex.current !== index) {
        const from = animatingToIndex.current === -1 ? lastReportedIndex.current : animatingToIndex.current;
        onAnimate?.(from, index, positionOf(from), position);
        animatingToIndex.current = index;
      }
      if (phase === 1) {
        animatingToIndex.current = index;
        fallbackIndex.current.value = index;
        fallbackPosition.current.value = position;
        if (lastReportedIndex.current !== index) {
          lastReportedIndex.current = index;
          onChange?.(index, position, type);
        }
      }
    },
    [onChange, onAnimate, positionOf, bottomInset],
  );

  const handleDragStart = useCallback(() => onDragStart?.(), [onDragStart]);
  const handleDragEnd = useCallback(() => onDragEnd?.(), [onDragEnd]);

  const bodyContent = presented ? renderProp(children, data as T) : null;
  const footerContent = presented && footer != null ? renderProp(footer, data as T) : null;

  // A Reanimated `useEvent` handler only reaches the view through a component
  // Reanimated itself created; the wrapped host is used whenever Reanimated
  // is available so the element type never changes.
  const Host = resolveHost(NativeBottomSheetView);

  return (
    <Host
      ref={nativeRef}
      style={styles.host}
      pointerEvents="none"
      detents={detentSpec}
      initialDetent={initialDetent}
      maxDetentInset={topInset}
      bottomInset={bottomInset}
      contentBottomInset={contentBottomInset}
      maxAutoHeight={maxDynamicContentSize ?? 0}
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
      enableContentPanningGesture={enableContentPanningGesture}
      enableHandlePanningGesture={enableHandlePanningGesture}
      enableOverDrag={enableOverDrag}
      overDragResistanceFactor={overDragResistanceFactor}
      keyboardMode={keyboardMode}
      expandOnKeyboard={expandOnKeyboard}
      restoreDetentOnKeyboardHide={restoreDetentOnKeyboardHide}
      dismissKeyboardOnDrag={props.enableBlurKeyboardOnGesture ?? dismissKeyboardOnDrag}
      detached={detached}
      detachedMargin={detachedMargin}
      hostStrategy={hostStrategy}
      positionEventsEnabled={positionEventsEnabled}
      onPresent={handlePresent}
      onDismiss={handleDismiss}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onLayoutChange={handleLayoutChange}
      onPositionChange={positionHandler as any}
    >
      {presented ? (
        <BottomSheetNativeLayoutContext.Provider value={layout}>
          <BottomSheetNativeActionsContext.Provider value={actions}>
            <BottomSheetNativeAnimatedContext.Provider value={animatedValue}>
              {CustomHandle != null ? (
                <View
                  nativeID={SHEET_HANDLE_ID}
                  collapsable={false}
                  style={[styles.child, { width: windowWidth - 2 * (detached ? detachedMargin : 0) }]}
                >
                  <CustomHandle
                    animatedIndex={animatedValue.animatedIndex}
                    animatedPosition={animatedValue.animatedPosition}
                  />
                </View>
              ) : null}
              <View
                nativeID={SHEET_BODY_ID}
                collapsable={false}
                style={[
                  styles.child,
                  { width: windowWidth - 2 * (detached ? detachedMargin : 0) },
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
                  style={[styles.child, { width: windowWidth - 2 * (detached ? detachedMargin : 0) }, footerStyle]}
                >
                  {footerContent}
                </View>
              ) : null}
            </BottomSheetNativeAnimatedContext.Provider>
          </BottomSheetNativeActionsContext.Provider>
        </BottomSheetNativeLayoutContext.Provider>
      ) : null}
    </Host>
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

/** gorhom's `useBottomSheetModal()`: dismiss the top sheet, one by name, or all. */
export function useBottomSheetModal(): { dismiss: (name?: string) => boolean; dismissAll: () => void } {
  return useMemo(
    () => ({
      dismiss: (name?: string) => sheetStack.dismiss(name),
      dismissAll: () => sheetStack.dismissAll(),
    }),
    [],
  );
}

/** Dismiss every presented sheet (outside React). */
export const dismissAllSheets = (): void => sheetStack.dismissAll();

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
