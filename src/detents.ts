/**
 * A detent is `'auto'` (content height), a fraction in (0, 1] of the
 * available height, or a dp value > 1. Must be listed in ascending order —
 * index 0 is the lowest, the last is the top.
 */
export type Detent = number | 'auto';

export const SHEET_BODY_ID = 'sheet-body';
export const SHEET_FOOTER_ID = 'sheet-footer';

/** Serialise for the native prop (arrays never travel over the bridge). */
export function serializeDetents(detents: ReadonlyArray<Detent> | string): string {
  if (typeof detents === 'string') return detents;
  return detents.map(d => (d === 'auto' ? 'auto' : String(d))).join(',');
}

/**
 * JS-side estimate of a detent's sheet height, used only for the body's
 * FIRST layout (before native has reported the exact value). Native corrects
 * it through `onLayoutChange` within the presentation animation.
 */
export function estimateSheetHeight(detent: Detent, availableHeight: number): number | null {
  if (detent === 'auto') return null;
  if (detent > 0 && detent <= 1) return detent * availableHeight;
  return Math.min(detent, availableHeight);
}
