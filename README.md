# react-native-bottom-sheet-native

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
import { BottomSheetNative, type BottomSheetNativeRef } from 'react-native-bottom-sheet-native';

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
`snapToIndex(i)`, `expand()`, `collapse()`, `isPresented()`.

## Props

### Sizing
| prop | notes |
|---|---|
| `snapPoints` | gorhom-style: `'60%'`, dp number, `'CONTENT_HEIGHT'`. Ascending. Takes precedence over `detents`. |
| `detents` | native form: `'auto'`, fraction `(0, 1]`, or dp. Default `['auto']`. |
| `index` / `initialDetent` | initial snap index |
| `enableDynamicSizing` | appends a `CONTENT_HEIGHT` detent |
| `topInset` | the tallest detent never enters it (safe-area top) |
| `bottomInset` | raise the resting bottom edge — e.g. above a tab bar |

### Chrome
| prop | notes |
|---|---|
| `backgroundStyle` | `backgroundColor`, `borderTopLeftRadius`/`borderRadius` honoured |
| `backgroundColor`, `cornerRadius` | native-form equivalents |
| `handleIndicatorStyle` | `backgroundColor`, `width`, `height` honoured |
| `handleComponent={null}` / `grabber={false}` | hide the grabber (the body starts at the top) |
| `grabberColor`, `grabberWidth`, `grabberHeight`, `grabberAreaHeight` | native-form equivalents |
| `backdropColor`, `backdropOpacity` / `dimmed`, `dimOpacity` | backdrop; `backdropOpacity={0}` disables it and lets touches through |
| `dismissOnBackdropPress` | default `true` (gorhom's `pressBehavior="close"`) |

### Behaviour
| prop | notes |
|---|---|
| `enablePanDownToClose` / `enablePanToDismiss` | drag below the lowest detent dismisses (default `true`) |
| `keyboardBehavior` | `'extend'`/`'fillParent'` spring to the top detent when the keyboard opens; `'interactive'` only lifts the footer |
| `expandOnKeyboard`, `dismissKeyboardOnDrag`, `keyboardMode` | native-form equivalents |
| `hostStrategy` | `'outermost-screen'` (default: covers a tab bar, under every stack push) or `'nearest-screen'` |

### Events
`onPresent`, `onDismiss(reason)`, `onAnimate(from, to)` (detent animation
starting), `onChange(index)` (settled; `-1` on dismiss), `onDragStart`, `onDragEnd`.

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
- `useBottomSheetNativeActions()` inside content: `snapToIndex`, `expand`,
  `collapse`, `close`, `dismiss`.
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
