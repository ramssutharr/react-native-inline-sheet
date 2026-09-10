import UIKit

/// The native sheet on iOS. Counterpart of Android's `SheetLayerView`; same
/// JS contract (`NativeBottomSheetNativeComponent.ts`).
///
/// This view itself is only a parking lot for the React children Fabric
/// mounts under the host: it is hidden and zero-size. On `present` it builds
/// a `SheetLayerView` (dim + sheet container + slots) and attaches it to the
/// hosting screen's own native view — the OUTERMOST `RNSScreenView` on the
/// way up (the main-stack screen that hosts the whole tab navigator), so the
/// sheet covers the tab bar but sits BELOW anything the stack pushes. Body
/// and footer children are moved into the container's slots; Fabric keeps
/// owning their layout (bounds + center at (0,0) inside the slot), we only
/// move the slots.
///
/// Geometry (points, layer-relative), driven by `visibleHeight`:
///
///   container : (0, H - visible, W, H + overshoot)   — full height so the
///               background never shows a gap under a spring overshoot
///   bodySlot  : (0, grabberArea, W, footerTop - grabberArea), clips
///   footerSlot: (0, footerTop, W, footerH) with
///               footerTop = visible - keyboardLift - footerH
///   dim       : layer bounds, alpha = dimOpacity * min(1, visible / detent0)
///
/// Everything RN-specific (finding the body's RN scroll view, cancelling
/// React's in-flight JS touches) is injected by NativeBottomSheet.mm, so this
/// file stays plain UIKit.
@objc(NativeBottomSheetContent)
public final class NativeBottomSheetContent: UIView, UIGestureRecognizerDelegate {

  // MARK: - Callbacks into the Fabric host

  @objc public var onPresent: (() -> Void)?
  @objc public var onDismiss: ((String) -> Void)?
  @objc public var onDragStart: (() -> Void)?
  @objc public var onDragEnd: (() -> Void)?
  /// (index, sheetHeight, bodyHeight (-1 = auto), maxBodyHeight (-1 = all auto), footerHeight, keyboardHeight, phase)
  @objc public var onLayoutChange: ((Int, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Int) -> Void)?
  /// Provided by the host: cancels React's in-flight JS touches so a press
  /// under the finger never fires once the sheet owns the drag.
  @objc public var cancelReactTouches: (() -> Void)?
  /// Given the mounted body root, returns its main vertical RN scroll view.
  /// RN-specific, so it lives on the ObjC++ side; a plain-UIKit fallback
  /// walks the subtree here.
  @objc public var scrollViewResolver: ((UIView) -> UIScrollView?)?

  // MARK: - Configuration (props)

  private enum Detent {
    case auto
    case fraction(CGFloat)
    case points(CGFloat)
  }

  private var detents: [Detent] = [.auto]
  private var initialDetent = 0
  private var maxDetentInset: CGFloat = 0
  private var bottomInset: CGFloat = 0
  private var dimmed = true
  private var dimOpacity: CGFloat = 0.5
  private var dimColor: UIColor = .black
  private var cornerRadius: CGFloat = 24
  private var grabberVisible = true
  private var grabberAreaHeight: CGFloat = 22
  private var sheetBackgroundColor: UIColor = .systemBackground
  private var grabberColor: UIColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
  private var grabberSize = CGSize(width: 36, height: 5)
  private var panToDismiss = true
  private var dismissOnBackdrop = true
  private var keyboardMode = "lift-footer"
  private var expandOnKeyboard = true
  private var dismissKeyboardOnDrag = true
  private var hostStrategy = "outermost-screen"

  // MARK: - React children

  private weak var bodyChild: UIView?
  private weak var footerChild: UIView?
  private var bodyObservation: NSKeyValueObservation?
  private var footerObservation: NSKeyValueObservation?
  /// The body's Fabric-assigned height — what an `auto` detent measures.
  private var bodyAutoHeight: CGFloat = 0
  private var footerHeight: CGFloat = 0

  // MARK: - Sheet state

  private var sheetLayer: SheetLayerView?
  private var isPresented = false
  private var currentIndex = 0
  private var visibleHeight: CGFloat = 0
  private var keyboardLift: CGFloat = 0
  /// Bumped on every new animation so a superseded completion is ignored.
  private var animationGeneration = 0

  private struct Emitted: Equatable {
    var index: Int
    var sheet: CGFloat
    var body: CGFloat
    var maxBody: CGFloat
    var footer: CGFloat
    var keyboard: CGFloat
    var phase: Int
  }
  private var lastEmitted: Emitted?

  // MARK: - Drag state

  private enum DragOwner { case undecided, sheet, content }
  private var sheetPan: UIPanGestureRecognizer?
  private var dragOwner: DragOwner = .undecided
  private var dragStartHeight: CGFloat = 0
  private var dragScrollView: UIScrollView?
  private var dragTouchInScroll = false
  private var lastTranslationY: CGFloat = 0
  private var dragEmittedStart = false
  /// The body's main scroll view, kept at offset 0 whenever the sheet is not
  /// fully expanded (gorhom's rule) — independent of any gesture, so a pan
  /// UIKit declined to begin cannot let the list slip.
  private weak var lockedScrollView: UIScrollView?
  private var lockObservation: NSKeyValueObservation?
  private var isLocking = false
  /// True only once a settle to the TOP detent has completed. Not derived
  /// from `visibleHeight`: inside a UIView spring the model value is already
  /// the target, which would free the list while the sheet is still rising.
  private var contentUnlocked = false

  private static let overshoot: CGFloat = 240

  // MARK: - Init

  public override init(frame: CGRect) {
    super.init(frame: frame)
    // Never visible: only a holding area for children before they are slotted.
    isHidden = true
    clipsToBounds = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillChange(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardWillChange(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Props

  @objc public func setDetents(_ spec: String) {
    let parsed: [Detent] = spec.split(separator: ",").compactMap { token in
      let t = token.trimmingCharacters(in: .whitespaces)
      if t == "auto" { return .auto }
      guard let v = Double(t), v > 0 else { return nil }
      return v <= 1 ? .fraction(CGFloat(v)) : .points(CGFloat(v))
    }
    detents = parsed.isEmpty ? [.auto] : parsed
    guard isPresented else { return }
    currentIndex = min(currentIndex, detents.count - 1)
    settleToCurrent(velocity: 0)
  }

  @objc public func setInitialDetent(_ index: Int) { initialDetent = index }
  @objc public func setMaxDetentInset(_ inset: CGFloat) {
    maxDetentInset = inset
    if isPresented { settleToCurrent(velocity: 0) }
  }
  @objc public func setBottomInset(_ inset: CGFloat) {
    bottomInset = inset
    if isPresented { settleToCurrent(velocity: 0) }
  }
  @objc public func setDimColor(_ color: UIColor?) { dimColor = color ?? .black; applyChrome() }
  @objc public func setGrabberWidth(_ value: CGFloat) { grabberSize.width = value; layoutSheet() }
  @objc public func setGrabberHeight(_ value: CGFloat) { grabberSize.height = value; applyChrome(); layoutSheet() }
  @objc public func setDimmed(_ value: Bool) { dimmed = value; layoutSheet() }
  @objc public func setDimOpacity(_ value: CGFloat) { dimOpacity = value; layoutSheet() }
  @objc public func setCornerRadius(_ value: CGFloat) { cornerRadius = value; applyChrome() }
  @objc public func setGrabber(_ value: Bool) {
    grabberVisible = value
    layoutSheet()
    if isPresented { emitLayout(phase: 1) }
  }
  @objc public func setGrabberAreaHeight(_ value: CGFloat) {
    grabberAreaHeight = value
    layoutSheet()
    if isPresented { emitLayout(phase: 1) }
  }
  @objc public func setSheetBackgroundColor(_ color: UIColor?) {
    sheetBackgroundColor = color ?? .systemBackground
    applyChrome()
  }
  @objc public func setGrabberColor(_ color: UIColor?) {
    grabberColor = color ?? UIColor.secondaryLabel.withAlphaComponent(0.5)
    applyChrome()
  }
  @objc public func setEnablePanToDismiss(_ value: Bool) { panToDismiss = value }
  @objc public func setDismissOnBackdropPress(_ value: Bool) { dismissOnBackdrop = value }
  @objc public func setKeyboardMode(_ value: String) { keyboardMode = value }
  @objc public func setExpandOnKeyboard(_ value: Bool) { expandOnKeyboard = value }
  @objc public func setDismissKeyboardOnDrag(_ value: Bool) { dismissKeyboardOnDrag = value }
  @objc public func setHostStrategy(_ value: String) { hostStrategy = value }

  // MARK: - Children

  @objc public func mountChild(_ child: UIView, nativeId: String?) {
    switch nativeId {
    case "sheet-body":
      bodyChild = child
      // Self-sufficient sizing: Fabric writes the child's layout straight
      // into its layer bounds — observe them rather than waiting on a JS
      // onLayout → prop round trip.
      bodyObservation = child.layer.observe(\.bounds, options: [.initial, .new]) { [weak self] layer, _ in
        let height = layer.bounds.height
        DispatchQueue.main.async { self?.bodyHeightChanged(height) }
      }
      (slotIfPresented(\.bodySlot) ?? self).addSubview(child)
    case "sheet-footer":
      footerChild = child
      footerObservation = child.layer.observe(\.bounds, options: [.initial, .new]) { [weak self] layer, _ in
        let height = layer.bounds.height
        DispatchQueue.main.async { self?.footerHeightChanged(height) }
      }
      (slotIfPresented(\.footerSlot) ?? self).addSubview(child)
    default:
      addSubview(child)
    }
  }

  @objc public func unmountChild(_ child: UIView) {
    if bodyChild === child {
      bodyObservation = nil
      bodyChild = nil
      bodyAutoHeight = 0
    }
    if footerChild === child {
      footerObservation = nil
      footerChild = nil
      footerHeight = 0
      layoutSheet()
    }
    child.removeFromSuperview()
  }

  private func slotIfPresented(_ slot: KeyPath<SheetLayerView, UIView>) -> UIView? {
    guard let layer = sheetLayer, layer.superview != nil else { return nil }
    return layer[keyPath: slot]
  }

  private func attachChildrenToSlots() {
    guard let layer = sheetLayer else { return }
    if let body = bodyChild, body.superview !== layer.bodySlot { layer.bodySlot.addSubview(body) }
    if let footer = footerChild, footer.superview !== layer.footerSlot { layer.footerSlot.addSubview(footer) }
  }

  private func bodyHeightChanged(_ height: CGFloat) {
    refreshContentLock()
    guard abs(height - bodyAutoHeight) > 0.5 else { return }
    bodyAutoHeight = height
    guard isPresented, isAuto(currentIndex) else { return }
    settleToCurrent(velocity: 0)
  }

  private func footerHeightChanged(_ height: CGFloat) {
    guard abs(height - footerHeight) > 0.5 else { return }
    footerHeight = height
    layoutSheet()
    guard isPresented else { return }
    if isAuto(currentIndex) {
      settleToCurrent(velocity: 0)
    } else {
      emitLayout(phase: 1)
    }
  }

  // MARK: - Commands

  @objc public func present(_ index: Int) {
    guard let host = resolveHost() else { return }
    let layer = sheetLayer ?? makeLayer()
    if layer.superview !== host {
      layer.removeFromSuperview()
      layer.frame = host.bounds
      layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.addSubview(layer)
    } else {
      // Always the LAST subview: RNSScreenView mounts its own RN children by
      // index, so anything of ours must stay after them.
      host.bringSubviewToFront(layer)
    }
    layer.frame = host.bounds
    attachChildrenToSlots()
    refreshContentLock()

    let wasPresented = isPresented
    isPresented = true
    currentIndex = clampIndex(index)
    if !wasPresented {
      visibleHeight = 0
      keyboardLift = 0
      lastEmitted = nil
      layoutSheet()
      onPresent?()
    }
    settleToCurrent(velocity: 0)
  }

  @objc public func dismiss() {
    dismiss(reason: "programmatic")
  }

  @objc public func snapTo(_ index: Int) {
    guard isPresented else { return }
    currentIndex = clampIndex(index)
    settleToCurrent(velocity: 0)
  }

  /// Recycled / unmounted by Fabric: tear everything down synchronously.
  @objc public func reset() {
    animationGeneration += 1
    contentUnlocked = false
    lockObservation = nil
    lockedScrollView = nil
    dragOwner = .undecided
    dragScrollView = nil
    if isPresented {
      isPresented = false
      onDismiss?("unmounted")
    }
    sheetLayer?.removeFromSuperview()
    sheetLayer = nil
    sheetPan = nil
    bodyObservation = nil
    footerObservation = nil
    bodyChild?.removeFromSuperview()
    footerChild?.removeFromSuperview()
    bodyChild = nil
    footerChild = nil
    bodyAutoHeight = 0
    footerHeight = 0
    visibleHeight = 0
    keyboardLift = 0
    currentIndex = 0
    lastEmitted = nil
  }

  private func dismiss(reason: String) {
    guard isPresented else { return }
    isPresented = false
    contentUnlocked = false
    lockObservation = nil
    lockedScrollView = nil
    dragOwner = .undecided
    dragScrollView = nil
    if dragEmittedStart {
      dragEmittedStart = false
      onDragEnd?()
    }
    animate(to: 0, velocity: 0) { [weak self] _ in
      guard let self, !self.isPresented else { return }
      self.sheetLayer?.removeFromSuperview()
      self.keyboardLift = 0
      self.lastEmitted = nil
      // Emitted AFTER the slide-out so JS keeps the content mounted until
      // the sheet is actually gone.
      self.onDismiss?(reason)
    }
  }

  // MARK: - Detents

  private var grabberArea: CGFloat { grabberVisible ? grabberAreaHeight : 0 }

  private func clampIndex(_ index: Int) -> Int {
    max(0, min(index, detents.count - 1))
  }

  private func isAuto(_ index: Int) -> Bool {
    if case .auto = detents[clampIndex(index)] { return true }
    return false
  }

  private func availableHeight() -> CGFloat {
    max(0, (sheetLayer?.bounds.height ?? 0) - maxDetentInset - bottomInset)
  }

  private func resolvedHeight(_ index: Int) -> CGFloat {
    let available = availableHeight()
    switch detents[clampIndex(index)] {
    case .auto:
      return min(available, bodyAutoHeight + grabberArea + footerHeight)
    case .fraction(let f):
      return f * available
    case .points(let p):
      return min(p, available)
    }
  }

  private var resolvedHeights: [CGFloat] { detents.indices.map(resolvedHeight) }
  /// Body height at the tallest non-auto detent; -1 when every detent is auto.
  private var maxBodyHeight: CGFloat {
    let fixed = detents.indices.filter { !isAuto($0) }.map(resolvedHeight)
    guard let top = fixed.max() else { return -1 }
    return max(0, top - grabberArea - footerHeight)
  }
  private var topHeight: CGFloat { resolvedHeights.max() ?? 0 }
  private var topIndex: Int {
    let heights = resolvedHeights
    guard let maxHeight = heights.max(), let index = heights.firstIndex(of: maxHeight) else { return 0 }
    return index
  }
  private var bottomHeight: CGFloat { resolvedHeights.min() ?? 0 }

  // MARK: - Layer + layout

  private func makeLayer() -> SheetLayerView {
    let layer = SheetLayerView()
    layer.owner = self
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.delegate = self
    // Coexist with RN's surface touch handler — never cancel view touch
    // delivery ourselves; JS touches are cancelled explicitly when the sheet
    // takes the drag (see cancelReactTouches).
    pan.cancelsTouchesInView = false
    layer.container.addGestureRecognizer(pan)
    sheetPan = pan
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
    layer.dimView.addGestureRecognizer(tap)
    sheetLayer = layer
    applyChrome()
    return layer
  }

  private func applyChrome() {
    guard let layer = sheetLayer else { return }
    layer.container.backgroundColor = sheetBackgroundColor
    layer.container.layer.cornerRadius = cornerRadius
    layer.dimView.backgroundColor = dimColor
    layer.grabber.backgroundColor = grabberColor
    layer.grabber.layer.cornerRadius = grabberSize.height / 2
  }

  fileprivate func layoutSheet() {
    guard let layer = sheetLayer else { return }
    let w = layer.bounds.width
    let h = layer.bounds.height
    layer.dimView.frame = layer.bounds
    let first = resolvedHeight(0)
    let progress = first > 0 ? min(1, max(0, visibleHeight / first)) : 1
    layer.dimView.alpha = dimmed ? dimOpacity * progress : 0
    layer.dimView.isUserInteractionEnabled = dimmed

    // `bottomInset` lifts the resting bottom edge (above a tab bar, say);
    // everything else is measured from that edge.
    layer.container.frame = CGRect(x: 0, y: h - bottomInset - visibleHeight, width: w, height: h + Self.overshoot)
    layer.grabber.isHidden = !grabberVisible
    layer.grabber.frame = CGRect(
      x: (w - grabberSize.width) / 2, y: 8,
      width: grabberSize.width, height: grabberSize.height)
    // Pinned to the screen's bottom edge while the sheet sits at or above its
    // lowest detent; below that (dragging to dismiss, the slide in/out) it
    // stays anchored at the lowest detent and travels with the sheet — the
    // Instagram footer.
    let anchor = max(visibleHeight, bottomHeight)
    let footerTop = max(0, anchor - keyboardLift - footerHeight)
    layer.footerSlot.frame = CGRect(x: 0, y: footerTop, width: w, height: footerHeight)
    layer.bodySlot.frame = CGRect(x: 0, y: grabberArea, width: w, height: max(0, footerTop - grabberArea))
  }

  fileprivate var blocksBackdropTouches: Bool { isPresented && dimmed }

  private func resolveHost() -> UIView? {
    var probe: UIView? = superview
    var nearest: UIView?
    var outermost: UIView?
    while let view = probe {
      if String(describing: type(of: view)) == "RNSScreenView" {
        if nearest == nil { nearest = view }
        outermost = view
      }
      probe = view.superview
    }
    return (hostStrategy == "nearest-screen" ? nearest : outermost) ?? window
  }

  // MARK: - Animation

  private func settleToCurrent(velocity: CGFloat) {
    contentUnlocked = false
    emitLayout(phase: 0)
    animate(to: resolvedHeight(currentIndex), velocity: velocity) { [weak self] finished in
      guard let self, finished, self.isPresented else { return }
      self.contentUnlocked = self.currentIndex == self.topIndex
      self.emitLayout(phase: 1)
    }
  }

  private func animate(to target: CGFloat, velocity: CGFloat, completion: ((Bool) -> Void)? = nil) {
    animationGeneration += 1
    let generation = animationGeneration
    let distance = abs(target - visibleHeight)
    let springVelocity = distance > 1 ? min(abs(velocity) / distance, 12) : 0
    UIView.animate(
      withDuration: 0.5,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: springVelocity,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.visibleHeight = target
      self.layoutSheet()
    } completion: { finished in
      guard generation == self.animationGeneration else { return }
      completion?(finished)
    }
  }

  /// A finger landed mid-spring: freeze the model at the presentation value.
  private func freezeAtPresentation() {
    guard let layer = sheetLayer else { return }
    if let presentation = layer.container.layer.presentation() {
      visibleHeight = max(0, layer.bounds.height - bottomInset - presentation.frame.minY)
    }
    animationGeneration += 1
    [layer.container, layer.dimView, layer.grabber, layer.bodySlot, layer.footerSlot]
      .forEach { $0.layer.removeAllAnimations() }
    layoutSheet()
  }

  private func emitLayout(phase: Int) {
    guard isPresented else { return }
    let sheet = resolvedHeight(currentIndex)
    let body: CGFloat = isAuto(currentIndex) ? -1 : max(0, sheet - grabberArea - footerHeight)
    let next = Emitted(
      index: currentIndex, sheet: sheet, body: body, maxBody: maxBodyHeight,
      footer: footerHeight, keyboard: keyboardLift, phase: phase)
    if next == lastEmitted { return }
    lastEmitted = next
    onLayoutChange?(next.index, next.sheet, next.body, next.maxBody, next.footer, next.keyboard, next.phase)
  }

  // MARK: - Drag

  @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
    guard let layer = sheetLayer, isPresented else { return }
    let translation = pan.translation(in: layer)
    switch pan.state {
    case .began:
      freezeAtPresentation()
      dragOwner = .undecided
      dragStartHeight = visibleHeight
      lastTranslationY = 0
      dragScrollView = resolveScrollView()
      if let scrollView = dragScrollView {
        dragTouchInScroll = scrollView.bounds.contains(pan.location(in: scrollView))
      } else {
        dragTouchInScroll = false
      }
      // Below the top detent the sheet owns the whole gesture, whichever way
      // it goes, and the list stays locked at offset 0 (gorhom's rule). Decide
      // now, not on the first move, so the list cannot slip a frame first.
      refreshContentLock()
      // A touch landing while the settle is still finishing: the sheet is
      // frozen at its PRESENTATION height above, so if that is already the
      // top, treat it as expanded now — otherwise this gesture would be
      // spent on a sheet that cannot rise, and the list would feel stuck.
      if visibleHeight >= topHeight - 0.5 {
        visibleHeight = topHeight
        currentIndex = topIndex
        contentUnlocked = true
        layoutSheet()
      }
      if !contentUnlocked {
        dragOwner = .sheet
        beginSheetOwnership()
      }
    case .changed:
      let dy = translation.y - lastTranslationY
      lastTranslationY = translation.y
      if dragOwner == .undecided { decideOwner(dy: dy) }
      switch dragOwner {
      case .sheet:
        applyDrag(height: dragStartHeight - translation.y)
        // Header hit the top while the finger is still pushing up over the
        // list: the list takes the rest of this gesture. Its pan has been
        // tracking all along (only its offset was held), so it continues
        // without a jump. A fling that releases early never gets here — the
        // settle keeps the list locked until it lands.
        if dragTouchInScroll, dy < 0, dragScrollView != nil, visibleHeight >= topHeight - 0.5 {
          visibleHeight = topHeight
          currentIndex = topIndex
          layoutSheet()
          contentUnlocked = true
          dragOwner = .content
        }
      case .content:
        // The list scrolled back to its top while the finger is still down
        // and now moves downward: the sheet takes over (the Instagram feel).
        if dragTouchInScroll, dy > 0, let scrollView = dragScrollView, scrollView.contentOffset.y <= 0.5 {
          dragOwner = .sheet
          dragStartHeight = visibleHeight
          pan.setTranslation(.zero, in: layer)
          lastTranslationY = 0
          enforceContentLock(scrollView)
          beginSheetOwnership()
        }
      case .undecided:
        break
      }
    case .ended, .cancelled, .failed:
      finishDrag(velocityY: pan.velocity(in: layer).y)
    default:
      break
    }
  }

  /// Only reached when the gesture began with the sheet fully expanded.
  private func decideOwner(dy: CGFloat) {
    guard dy != 0 else { return }
    let owner: DragOwner
    if !dragTouchInScroll || dragScrollView == nil {
      owner = .sheet
    } else if dy > 0 {
      // Pulling down at the list's top drags the sheet; anywhere else scrolls.
      owner = (dragScrollView?.contentOffset.y ?? 0) <= 0.5 ? .sheet : .content
    } else {
      owner = .content
    }
    dragOwner = owner
    if owner == .sheet {
      if let scrollView = dragScrollView { enforceContentLock(scrollView) }
      beginSheetOwnership()
    }
  }

  private func beginSheetOwnership() {
    contentUnlocked = false
    cancelReactTouches?()
    if dismissKeyboardOnDrag, keyboardLift > 0 {
      // Whatever is first responder (the footer's input) resigns; the
      // keyboard's own notification then animates the footer back down.
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    if !dragEmittedStart {
      dragEmittedStart = true
      onDragStart?()
    }
  }

  private func applyDrag(height: CGFloat) {
    var target = height
    let top = topHeight
    let bottom = bottomHeight
    if target > top {
      // Hard stop at the top detent (IG / gorhom), no rubber band.
      target = top
    } else if target < bottom && !panToDismiss {
      target = bottom - (bottom - target) * 0.2
    }
    visibleHeight = max(0, target)
    layoutSheet()
  }

  private func finishDrag(velocityY: CGFloat) {
    let owned = dragOwner == .sheet
    if owned {
      if let scrollView = dragScrollView ?? lockedScrollView {
        // The list's pan tracked the whole drag with its offset pinned; left
        // alone it would now fling from the release velocity.
        killScroll(scrollView)
      }
      settle(velocityY: velocityY)
    }
    if dragEmittedStart {
      dragEmittedStart = false
      onDragEnd?()
    }
    dragOwner = .undecided
    dragScrollView = nil
  }

  private func settle(velocityY: CGFloat) {
    let heights = resolvedHeights
    guard !heights.isEmpty else { return }
    // Project the release the way UIKit decelerates, then pick the nearest detent.
    let projected = visibleHeight - velocityY * 0.12
    let lowest = heights.min() ?? 0
    if panToDismiss && (projected < lowest * 0.5 || (velocityY > 1500 && visibleHeight <= lowest + 1)) {
      dismiss(reason: "drag")
      return
    }
    var best = 0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for (index, height) in heights.enumerated() {
      let distance = abs(height - projected)
      if distance < bestDistance {
        bestDistance = distance
        best = index
      }
    }
    currentIndex = best
    settleToCurrent(velocity: -velocityY)
  }

  // MARK: - Content lock (gorhom's rule)

  /// Observe the body's scroll view so `enforceContentLock` runs on every
  /// offset write — UIKit's own tracking included. KVO fires inside the
  /// setter, before the frame is drawn, so a rejected scroll never shows.
  private func refreshContentLock() {
    guard isPresented, let scrollView = resolveScrollView() else {
      lockObservation = nil
      lockedScrollView = nil
      return
    }
    if scrollView === lockedScrollView, lockObservation != nil { return }
    lockedScrollView = scrollView
    lockObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
      self?.enforceContentLock(scrollView)
    }
    enforceContentLock(scrollView)
  }

  /// The list may scroll only while the sheet is fully expanded AND no drag
  /// is owned by the sheet; otherwise its offset is held at 0.
  /// Where the sheet actually is on screen right now (presentation layer),
  /// not where its model says it is heading.
  private func isAtTopOnScreen() -> Bool {
    guard let layer = sheetLayer else { return false }
    let minY = layer.container.layer.presentation()?.frame.minY ?? layer.container.frame.minY
    return layer.bounds.height - bottomInset - minY >= topHeight - 0.5
  }

  private func enforceContentLock(_ scrollView: UIScrollView) {
    guard !isLocking, isPresented else { return }
    // Self-healing: a sheet that is visibly at its top is scrollable whether
    // or not a settle completion managed to flip the flag (and even if our
    // own pan never began for this touch).
    if dragOwner != .sheet && (contentUnlocked || isAtTopOnScreen()) {
      if !contentUnlocked { contentUnlocked = true }
      return
    }
    guard scrollView.contentOffset.y != 0 else { return }
    isLocking = true
    scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: 0)
    if scrollView.isDecelerating {
      // A fling that started under the lock must die here, not just be held
      // at 0 — otherwise its remainder plays out the moment the lock opens.
      killScroll(scrollView)
    }
    isLocking = false
  }

  /// Stop a scroll view dead: cancel its pan (so a release cannot START a
  /// deceleration — toggling `isScrollEnabled` only stops tracking) and end
  /// any deceleration already running (`setContentOffset(_:animated:false)`
  /// is UIKit's documented way to halt one).
  private func killScroll(_ scrollView: UIScrollView) {
    let pan = scrollView.panGestureRecognizer
    pan.isEnabled = false
    pan.isEnabled = true
    let wasLocking = isLocking
    isLocking = true
    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: max(0, scrollView.contentOffset.y)), animated: false)
    isLocking = wasLocking
  }

  private func resolveScrollView() -> UIScrollView? {
    guard let body = bodyChild else { return nil }
    if let resolved = scrollViewResolver?(body) { return resolved }
    // Plain-UIKit fallback: breadth-first, first vertical scroll view.
    var queue: [UIView] = [body]
    var visited = 0
    while !queue.isEmpty && visited < 4000 {
      let view = queue.removeFirst()
      visited += 1
      if let scrollView = view as? UIScrollView,
         scrollView.contentSize.height >= scrollView.contentSize.width || scrollView.alwaysBounceVertical {
        return scrollView
      }
      queue.append(contentsOf: view.subviews)
    }
    return nil
  }

  // MARK: - UIGestureRecognizerDelegate

  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === sheetPan, let layer = sheetLayer else {
      return true
    }
    // Vertical intent only: sideways drags belong to carousels inside the
    // body. Accept EITHER velocity or translation dominance — a recognizer
    // that fails stays failed for the whole touch, so a slightly diagonal
    // start must not hand the gesture to the list.
    let velocity = pan.velocity(in: layer)
    let translation = pan.translation(in: layer)
    return abs(velocity.y) > abs(velocity.x) || abs(translation.y) > abs(translation.x)
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    guard gestureRecognizer === sheetPan else { return false }
    // Run alongside any scroll view's pan: the state machine decides who
    // moves, and the list's offset is pinned while the sheet owns it.
    return otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
  }

  // MARK: - Backdrop

  @objc private func handleBackdropTap() {
    guard dismissOnBackdrop else { return }
    dismiss(reason: "backdrop")
  }

  // MARK: - Keyboard

  @objc private func keyboardWillChange(_ notification: Notification) {
    guard isPresented, keyboardMode == "lift-footer",
          let layer = sheetLayer, let window = layer.window,
          let info = notification.userInfo,
          let endValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
    else { return }
    let endFrame = window.convert(endValue.cgRectValue, from: nil)
    let layerBottom = layer.convert(layer.bounds, to: window).maxY - bottomInset
    let lift: CGFloat = notification.name == UIResponder.keyboardWillHideNotification
      ? 0 : max(0, layerBottom - endFrame.minY)
    guard abs(lift - keyboardLift) > 0.5 else { return }
    keyboardLift = lift
    // The keyboard opening takes the sheet to its top detent (IG comments),
    // in the same animation as the footer lift so nothing moves twice.
    if lift > 0, expandOnKeyboard, currentIndex != topIndex {
      currentIndex = topIndex
    }
    contentUnlocked = false
    emitLayout(phase: 0)
    let target = resolvedHeight(currentIndex)
    let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    animationGeneration += 1
    let generation = animationGeneration
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.visibleHeight = target
      self.layoutSheet()
    } completion: { finished in
      guard generation == self.animationGeneration else { return }
      if finished { self.contentUnlocked = self.currentIndex == self.topIndex }
      self.emitLayout(phase: 1)
    }
  }

  // MARK: - The layer attached to the screen host

  fileprivate final class SheetLayerView: UIView {
    weak var owner: NativeBottomSheetContent?
    let dimView = UIView()
    let container = UIView()
    let grabber = UIView()
    let bodySlot = UIView()
    let footerSlot = UIView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      dimView.backgroundColor = .black
      dimView.alpha = 0
      addSubview(dimView)
      container.clipsToBounds = true
      container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      container.layer.cornerCurve = .continuous
      addSubview(container)
      grabber.layer.cornerRadius = 2.5
      container.addSubview(grabber)
      bodySlot.clipsToBounds = true
      container.addSubview(bodySlot)
      footerSlot.clipsToBounds = true
      container.addSubview(footerSlot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
      super.layoutSubviews()
      owner?.layoutSheet()
    }

    /// Outside the sheet: swallow touches when dimmed (tap = backdrop), let
    /// them through to the screen beneath otherwise.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let hit = super.hitTest(point, with: event)
      if hit === self || hit === dimView {
        return (owner?.blocksBackdropTouches ?? false) ? dimView : nil
      }
      return hit
    }
  }
}
