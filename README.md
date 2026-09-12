# react-native-inline-sheet

Instagram-style bottom sheet for React Native (Fabric / New Architecture).
The **frame** — present/dismiss, drag, detents, dim, scroll hand-off, keyboard —
is UIKit / Android View code and never touches the JS thread per frame. The
**content** is ordinary React.

Inline mode: the sheet attaches to the hosting screen's own native view, so it
sits above a tab bar but **below** anything the navigator pushes — tap a name in
comments, the profile slides over the open sheet, and popping reveals it exactly
as it was.

## Usage

```tsx
import { BottomSheetNative, type BottomSheetNativeRef } from 'react-native-inline-sheet';

const ref = useRef<BottomSheetNativeRef<{ postId: number }>>(null);

<BottomSheetNative
  ref={ref}
  snapPoints={['66%', '100%']}
  topInset={insets.top}
  footer={<Composer />}
>
  {({ data }) => <Comments postId={data.postId} />}
</BottomSheetNative>

ref.current?.present({ postId: 42 });
```

The ref has gorhom's shape: `present(data?)`, `dismiss()`, `close()`,
`forceClose()`, `snapToIndex(i)`, `snapToPosition(dp | '50%')`, `expand()`,
`collapse()`, `isPresented()`, plus `minimize()` / `restore()` (what the modal
stack does to the sheet underneath).

## Props

### Sizing
| prop | notes |
|---|---|
| `snapPoints` | gorhom-style: `'60%'`, dp number, `'CONTENT_HEIGHT'`. Ascending. Takes precedence over `detents`. |
| `detents` | native form: `'auto'`, fraction `(0, 1]`, or dp. Default `['auto']`. |
| `index` / `initialDetent` | initial snap index |
| `enableDynamicSizing` | adds a `CONTENT_HEIGHT` detent. Native sorts detents by their resolved height (gorhom's rule), so it lands wherever the content puts it and every index refers to that order. |
| `maxDynamicContentSize` | cap on the content-sized detent |
| `detached` | floating card: `style.marginHorizontal` (or `detachedMargin`) from the sides, `bottomInset` from the bottom, all corners rounded |
| `topInset` | the tallest detent never enters it (safe-area top) |
| `bottomInset` | raise the resting bottom edge — e.g. above a tab bar |
| `contentBottomInset` | the safe-area bottom your content pads with; not applied while the keyboard is open (the sheet rises by keyboard − this, so the padding sits over the keyboard) |

### Chrome
| prop | notes |
|---|---|
| `backgroundStyle` | `backgroundColor`, `borderTopLeftRadius`/`borderRadius` honoured |
| `backgroundColor`, `cornerRadius` | native-form equivalents |
| `handleIndicatorStyle` | `backgroundColor`, `width`, `height` honoured |
| `handleComponent={null}` / `grabber={false}` | hide the grabber (the body starts at the top) |
| `handleComponent={Handle}` | a custom handle, rendered natively in the handle slot; receives `animatedIndex` / `animatedPosition` |
| `grabberColor`, `grabberWidth`, `grabberHeight`, `grabberAreaHeight` | native-form equivalents |
| `backdropColor`, `backdropOpacity` / `dimmed`, `dimOpacity` | backdrop; `backdropOpacity={0}` disables it and lets touches through |
| `dismissOnBackdropPress` | default `true` (gorhom's `pressBehavior="close"`) |
| `backdropComponent` | accepted for drop-in compatibility, NOT rendered (the backdrop is native) |

### Behaviour
| prop | notes |
|---|---|
| `enablePanDownToClose` / `enablePanToDismiss` | drag below the lowest detent dismisses (default `true`) |
| `enableContentPanningGesture` | off: only the handle drags the sheet, the list scrolls freely at every detent |
| `enableHandlePanningGesture` | off: the handle area does not drag |
| `enableOverDrag`, `overDragResistanceFactor` | pull past the top detent with resistance (default on, 2.5 — gorhom's). `enableOverDrag={false}` makes the top a hard stop, Instagram's feel |
| `keyboardBehavior` | `'interactive'` (default, gorhom's): the whole sheet rises by the keyboard, and whatever it cannot rise the footer rises on its own; `'extend'`/`'fillParent'`: spring to the top detent and lift only the footer — Instagram's comments |
| `keyboardBlurBehavior="restore"` | return to the pre-keyboard detent once the keyboard hides |
| `enableBlurKeyboardOnGesture` / `dismissKeyboardOnDrag` | drop the keyboard as soon as the sheet takes a drag (default false, gorhom's) |
| `expandOnKeyboard`, `keyboardMode` | native-form equivalents |
| `mode` | `'inline'` (default: the screen's own layer, under stack pushes) or `'modal'` (React Native's root view, above every screen — what a `containerComponent={FullWindowOverlay}` did) |
| `hostStrategy` | native-form: `'outermost-screen'`, `'nearest-screen'`, `'root'` |
| `stackBehavior` | gorhom's modal stack, no provider needed: `'switch'` (default — the sheet on top slides out and comes back when this one is dismissed), `'push'`, `'replace'` |
| `name` | key for `useBottomSheetModal().dismiss(name)` |
| `presentOnMount`, `animateOnMount` | gorhom's non-modal `BottomSheet`: on screen from the start, optionally without animation |
| `animatedIndex`, `animatedPosition` | Reanimated shared values written on the UI thread per frame while the sheet moves (see below) |

### Events
`onPresent`, `onDismiss(reason)` / `onClose`, `onAnimate(from, to, fromPosition,
toPosition)` (detent animation starting), `onChange(index, position, type)`
(settled; `-1` on dismiss; `type` is `SNAP_POINT_TYPE.PROVIDED | DYNAMIC`),
`onDragStart`, `onDragEnd`.

## Animated values (Reanimated, optional)

With `react-native-reanimated` installed, the sheet's live position reaches
content on the UI thread — gorhom's `animatedIndex` (fractional, `-1` closed)
and `animatedPosition` (dp from the top) — with no JS-thread work per frame:

```tsx
const { animatedIndex, animatedPosition } = useBottomSheetAnimated(); // inside the sheet
// or gorhom's shape:
const { animatedIndex, snapToIndex, close } = useBottomSheet();
// or pass your own shared values in:
<BottomSheetNative animatedIndex={sheetIndex} />
```

The per-frame native event is armed only while something reads it. Without
Reanimated the same objects exist and update when the sheet settles.

## Stacking

`useBottomSheetModal()` returns `{ dismiss(name?), dismissAll() }`, and
`dismissAllSheets()` does the same outside React. Each sheet keeps its own
backdrop, as gorhom's modals do.

## Defaults

Every default matches `@gorhom/bottom-sheet` 5.x so a sheet ported without
touching its props behaves the same: `index` 0, `enableDynamicSizing` true,
`enablePanDownToClose` true, `enableOverDrag` true (resistance 2.5),
`keyboardBehavior` 'interactive', `keyboardBlurBehavior` 'none',
`enableBlurKeyboardOnGesture` false, `stackBehavior` 'switch', background
white with a 15dp radius, handle indicator 7.5% of the window wide × 4 high in
75% black inside a 24dp area, backdrop black at 0.5 closing on press (what
gorhom's `BottomSheetBackdrop` renders — gorhom itself draws none until you
pass one; use `backdropOpacity={0}` for that).

## Content

Children are re-parented natively by `nativeID`: the body (your children) and the
optional `footer`, which is pinned to the visible bottom and lifted over the
keyboard natively.

- Size the body's list for the **top** detent: it already is — the body child is
  sized to the tallest fixed detent so a drag upward never uncovers bare sheet.
  Pad the list's *scroll content* by `bottomInset + keyboardHeight` from
  `useBottomSheetNativeLayout()` so its end stays reachable at lower detents
  (never pad the list's container).
- Spread `sheetScrollableProps` onto the list (Android needs
  `nestedScrollEnabled` for the scroll ↔ sheet hand-off; iOS needs nothing).
- `useBottomSheetNativeActions()` inside content: `snapToIndex`,
  `snapToPosition`, `expand`, `collapse`, `close`, `forceClose`, `dismiss`.
- VoiceOver / TalkBack: the backdrop reads as a "tap to close" button and the
  handle as an adjustable control (swipe up/down moves between detents). The
  system's Reduce Motion / animator-scale settings shorten the springs.
- `SheetRouter` for multi-step content inside one sheet (push/pop with a slide;
  an `auto` detent follows each route's height).

## Gesture model (gorhom's)

The list is locked at offset 0 unless the sheet is fully expanded. A drag that
starts below the top moves the sheet; once the header hits the top *within the
same gesture*, the rest of it scrolls the list. A fling that releases early
settles the sheet with the list still locked. Pulling down at the list's top
hands the gesture to the sheet. The top detent is a hard stop.

## Install

Autolinked. iOS: `pod install` (also after any change to the codegen spec).
Ships untranspiled TypeScript — allow it through Jest's `transformIgnorePatterns`.
