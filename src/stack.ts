/**
 * gorhom's modal stack, without a provider: every presented sheet registers
 * here, and `stackBehavior` decides what presenting one does to the sheet
 * already on top.
 *
 *   - 'push'    — stacks on top (each sheet keeps its own dim)
 *   - 'switch'  — the sheet on top is MINIMISED (slid out, content kept
 *                 mounted) and comes back when the new one is dismissed
 *   - 'replace' — the sheet on top is dismissed for good
 */

export type StackBehavior = 'push' | 'switch' | 'replace';

export type StackEntry = {
  name: string;
  /** Slide out keeping the content mounted; `restore` brings it back. */
  minimize: () => void;
  restore: () => void;
  dismiss: () => void;
  isMinimized: () => boolean;
};

const entries: StackEntry[] = [];
/** presented sheet → the sheet it minimised (restored on its dismiss). */
const restoreLinks = new Map<StackEntry, StackEntry>();

function remove(entry: StackEntry) {
  const at = entries.indexOf(entry);
  if (at >= 0) entries.splice(at, 1);
}

/** The visible sheet on top, if any. */
function top(): StackEntry | undefined {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry != null && !entry.isMinimized()) return entry;
  }
  return undefined;
}

export const sheetStack = {
  willPresent(entry: StackEntry, behavior: StackBehavior) {
    remove(entry);
    const current = top();
    if (current != null && current !== entry) {
      if (behavior === 'switch') {
        current.minimize();
        restoreLinks.set(entry, current);
      } else if (behavior === 'replace') {
        current.dismiss();
      }
    }
    entries.push(entry);
  },

  /** A sheet is gone for good (dismissed or unmounted). */
  didDismiss(entry: StackEntry) {
    remove(entry);
    const below = restoreLinks.get(entry);
    restoreLinks.delete(entry);
    // A sheet this one had minimised comes back — unless something else has
    // taken the top meanwhile, or it has gone.
    if (below != null && entries.includes(below) && below.isMinimized() && top() == null) {
      below.restore();
    }
  },

  /** gorhom's `useBottomSheetModal().dismiss(name?)`: no name = the top sheet. */
  dismiss(name?: string): boolean {
    if (name == null) {
      const current = top();
      if (current == null) return false;
      current.dismiss();
      return true;
    }
    for (let i = entries.length - 1; i >= 0; i--) {
      const entry = entries[i];
      if (entry != null && entry.name === name) {
        entry.dismiss();
        return true;
      }
    }
    return false;
  },

  dismissAll() {
    [...entries].reverse().forEach(entry => entry.dismiss());
  },

  isPresented(name: string): boolean {
    return entries.some(entry => entry.name === name && !entry.isMinimized());
  },
};
