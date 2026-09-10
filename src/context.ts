import { createContext, useContext } from 'react';

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
  isPresented: boolean;
};

export type BottomSheetNativeActions = {
  snapToIndex: (index: number) => void;
  expand: () => void;
  collapse: () => void;
  close: () => void;
  dismiss: () => void;
};

export const BottomSheetNativeLayoutContext = createContext<BottomSheetNativeLayout>({
  index: -1,
  sheetHeight: 0,
  bodyHeight: null,
  maxBodyHeight: null,
  bottomInset: 0,
  footerHeight: 0,
  keyboardHeight: 0,
  isPresented: false,
});

export const BottomSheetNativeActionsContext = createContext<BottomSheetNativeActions>({
  snapToIndex: () => {},
  expand: () => {},
  collapse: () => {},
  close: () => {},
  dismiss: () => {},
});

/**
 * Read the host's settled geometry from inside the sheet's content — pad a
 * list's bottom by `footerHeight + keyboardHeight`, centre an empty state
 * in `bodyHeight`, etc. Updates only when the sheet settles, never per frame.
 */
export const useBottomSheetNativeLayout = (): BottomSheetNativeLayout =>
  useContext(BottomSheetNativeLayoutContext);

/** Imperative controls from inside the sheet's content (the gorhom `useBottomSheet()` shape). */
export const useBottomSheetNativeActions = (): BottomSheetNativeActions =>
  useContext(BottomSheetNativeActionsContext);
