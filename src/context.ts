import { createContext, useContext, useEffect } from 'react';
import type { SharedValueLike } from './animated';

export type BottomSheetNativeLayout = {
  /** Settled detent index (-1 while dismissed). */
  index: number;
  sheetHeight: number;
  /** Visible body height at the settled detent, or null for an `auto` detent. */
  bodyHeight: number | null;
  /**
   * The body child's actual height: the body at the TOP fixed detent (so a
   * drag upward never uncovers empty sheet), or null when content-sized.
   */
  maxBodyHeight: number | null;
  /**
   * How much of the body currently hangs below the visible edge
   * (`maxBodyHeight - bodyHeight`). Pad a list's scroll CONTENT
   * (`contentContainerStyle.paddingBottom`) by this plus `keyboardHeight`
   * so its end stays reachable at every detent. Never pad the list's
   * container: the scroll view must keep the full body height so the area
   * a drag reveals is already rendered.
   */
  bottomInset: number;
  footerHeight: number;
  keyboardHeight: number;
  /** The host layer's height; `hostHeight - sheetHeight` is gorhom's settled "position". */
  hostHeight: number;
  isPresented: boolean;
};

export type BottomSheetNativeActions = {
  snapToIndex: (index: number) => void;
  /** gorhom's `snapToPosition`: a dp number or a `'50%'` string. */
  snapToPosition: (position: number | string) => void;
  expand: () => void;
  collapse: () => void;
  close: () => void;
  forceClose: () => void;
  dismiss: () => void;
};

/**
 * gorhom's `animatedIndex` / `animatedPosition`. With Reanimated installed
 * these are real shared values written on the UI thread per frame while the
 * sheet moves; without it they are plain `{ value }` objects updated when
 * the sheet settles.
 */
export type BottomSheetNativeAnimated = {
  animatedIndex: SharedValueLike<number>;
  animatedPosition: SharedValueLike<number>;
  /** Arms the per-frame native event while a consumer is mounted. */
  subscribe: () => () => void;
};

export const BottomSheetNativeLayoutContext = createContext<BottomSheetNativeLayout>({
  index: -1,
  sheetHeight: 0,
  bodyHeight: null,
  maxBodyHeight: null,
  bottomInset: 0,
  footerHeight: 0,
  keyboardHeight: 0,
  hostHeight: 0,
  isPresented: false,
});

export const BottomSheetNativeActionsContext = createContext<BottomSheetNativeActions>({
  snapToIndex: () => {},
  snapToPosition: () => {},
  expand: () => {},
  collapse: () => {},
  close: () => {},
  forceClose: () => {},
  dismiss: () => {},
});

export const BottomSheetNativeAnimatedContext = createContext<BottomSheetNativeAnimated>({
  animatedIndex: { value: -1 },
  animatedPosition: { value: 0 },
  subscribe: () => () => {},
});

/**
 * Read the host's settled geometry from inside the sheet's content — pad a
 * list's bottom by `footerHeight + keyboardHeight`, centre an empty state
 * in `bodyHeight`, etc. Updates only when the sheet settles, never per frame.
 */
export const useBottomSheetNativeLayout = (): BottomSheetNativeLayout =>
  useContext(BottomSheetNativeLayoutContext);

/** Imperative controls from inside the sheet's content. */
export const useBottomSheetNativeActions = (): BottomSheetNativeActions =>
  useContext(BottomSheetNativeActionsContext);

/**
 * The sheet's live position as shared values, from inside its content.
 * Mounting a consumer arms the per-frame native event; nothing is emitted
 * for sheets that nobody tracks.
 */
export const useBottomSheetAnimated = (): {
  animatedIndex: SharedValueLike<number>;
  animatedPosition: SharedValueLike<number>;
} => {
  const { animatedIndex, animatedPosition, subscribe } = useContext(BottomSheetNativeAnimatedContext);
  useEffect(() => subscribe(), [subscribe]);
  return { animatedIndex, animatedPosition };
};

/** gorhom's `useBottomSheet()`: the methods plus `animatedIndex` / `animatedPosition`. */
export const useBottomSheet = (): BottomSheetNativeActions & {
  animatedIndex: SharedValueLike<number>;
  animatedPosition: SharedValueLike<number>;
} => {
  const actions = useBottomSheetNativeActions();
  const animated = useBottomSheetAnimated();
  return { ...actions, ...animated };
};
