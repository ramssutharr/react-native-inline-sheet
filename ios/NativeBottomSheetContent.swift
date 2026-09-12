import UIKit

/// The native sheet on iOS. Counterpart of Android's `SheetLayerView`; same
/// JS contract (`NativeBottomSheetNativeComponent.ts`).
///
/// This view itself is only a parking lot for the React children Fabric
/// mounts under the host: it is hidden and zero-size. On `present` it builds
/// a `SheetLayerView` (dim + sheet container + slots) and attaches it to the
/// hosting screen's own native view — the OUTERMOST `RNSScreenView` on the
/// way up (the main-stack screen that hosts the whole tab navigator), so the
/// sheet covers the tab bar but sits BELOW anything the stack pushes — or,
/// in modal mode, to React Native's root surface view above every screen.
/// Body, footer and handle children are moved into the container's slots;
/// Fabric keeps owning their layout (bounds + center at (0,0) inside the
/// slot), we only move the slots.
///
/// Geometry (points, layer-relative), driven by `visibleHeight`:
///
///   container : (m, H - visible, W - 2m, H + overshoot)  — full height so the
///               background never shows a gap under a spring overshoot
///               (detached: height = visible, all corners rounded)
///   handleSlot: (0, 0, W, handleArea)
///   bodySlot  : (0, handleArea, W, footerTop - handleArea), clips
///   footerSlot: (0, footerTop, W, footerH) with
///               footerTop = visible - keyboardLift - footerH   ('lift-footer')
///   'lift-sheet': the whole container rises by the keyboard instead
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
  /// (index, sheetHeight, bodyHeight (-1 = auto), maxBodyHeight (-1 = all auto), footerHeight, keyboardHeight, hostHeight, dynamic, phase)
  @objc public var onLayoutChange: ((Int, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Int, Int) -> Void)?
  /// (position, fractional index, visible height) — per frame while moving, only when armed.
  @objc public var onPositionChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
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
  private var maxAutoHeight: CGFloat = 0
  private var contentBottomInset: CGFloat = 0
  private var dimmed = true
  private var dimOpacity: CGFloat = 0.5
  private var dimColor: UIColor = .black
  private var cornerRadius: CGFloat = 15
  private var grabberVisible = true
  private var grabberAreaHeight: CGFloat = 24
  private var sheetBackgroundColor: UIColor = .white
  private var grabberColor: UIColor = UIColor.black.withAlphaComponent(0.75)
  private var grabberSize = CGSize(width: 30, height: 4)
  private var panToDismiss = true
  private var dismissOnBackdrop = true
  private var contentPanning = true
  private var handlePanning = true
  private var overDrag = true
  private var overDragResistance: CGFloat = 2.5
  private var keyboardMode = "lift-sheet"
  private var expandOnKeyboard = false
  private var restoreOnKeyboardHide = false
  private var dismissKeyboardOnDrag = false
  private var detached = false
  private var detachedMargin: CGFloat = 0
  private var hostStrategy = "outermost-screen"
  private var positionEvents = false

  // MARK: - React children

  private weak var bodyChild: UIView?
  private weak var footerChild: UIView?
  private weak var handleChild: UIView?
  private var bodyObservation: NSKeyValueObservation?
  private var footerObservation: NSKeyValueObservation?
  private var handleObservation: NSKeyValueObservation?
  /// The body's Fabric-assigned height — what an `auto` detent measures.
  private var bodyAutoHeight: CGFloat = 0
  private var footerHeight: CGFloat = 0
  private var handleHeight: CGFloat = 0

  // MARK: - Sheet state

  private var sheetLayer: SheetLayerView?
  private var isPresented = false
  private var currentIndex = 0
  /// A `snapToHeight` target that is not a detent (gorhom's temporary position).
  private var temporaryTarget: CGFloat?
  private var visibleHeight: CGFloat = 0
  private var keyboardLift: CGFloat = 0
  /// Where the sheet sat before the keyboard expanded it (for the restore).
  private var indexBeforeKeyboard: Int?
  /// Bumped on every new animation so a superseded completion is ignored.
  private var animationGeneration = 0
  private var displayLink: CADisplayLink?
  private var lastPosition: CGFloat = .nan

  private struct Emitted: Equatable {
    var index: Int
    var sheet: CGFloat
    var body: CGFloat
    var maxBody: CGFloat
    var footer: CGFloat
    var keyboard: CGFloat
    var host: CGFloat
    var dynamic: Int
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
  /// The touch began in the handle band (gorhom's GESTURE_SOURCE.HANDLE).
  private var dragInHandle = false
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
    displayLink?.invalidate()
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
    temporaryTarget = nil
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
  @objc public func setContentBottomInset(_ value: CGFloat) { contentBottomInset = max(0, value) }
  @objc public func setMaxAutoHeight(_ value: CGFloat) {
    maxAutoHeight = value
    if isPresented, isAuto(currentIndex) { settleToCurrent(velocity: 0) }
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
    sheetBackgroundColor = color ?? .white
    applyChrome()
  }
  @objc public func setGrabberColor(_ color: UIColor?) {
    grabberColor = color ?? UIColor.black.withAlphaComponent(0.75)
    applyChrome()
  }
  @objc public func setEnablePanToDismiss(_ value: Bool) { panToDismiss = value }
  @objc public func setDismissOnBackdropPress(_ value: Bool) { dismissOnBackdrop = value }
  @objc public func setEnableContentPanningGesture(_ value: Bool) {
    contentPanning = value
    refreshContentLock()
  }
  @objc public func setEnableHandlePanningGesture(_ value: Bool) { handlePanning = value }
  @objc public func setEnableOverDrag(_ value: Bool) { overDrag = value }
  @objc public func setOverDragResistanceFactor(_ value: CGFloat) { overDragResistance = max(1, value) }
  @objc public func setKeyboardMode(_ value: String) { keyboardMode = value }
  @objc public func setExpandOnKeyboard(_ value: Bool) { expandOnKeyboard = value }
  @objc public func setRestoreDetentOnKeyboardHide(_ value: Bool) { restoreOnKeyboardHide = value }
  @objc public func setDismissKeyboardOnDrag(_ value: Bool) { dismissKeyboardOnDrag = value }
  @objc public func setDetached(_ value: Bool) { detached = value; applyChrome(); layoutSheet() }
  @objc public func setDetachedMargin(_ value: CGFloat) { detachedMargin = max(0, value); layoutSheet() }
  @objc public func setHostStrategy(_ value: String) { hostStrategy = value }
  @objc public func setPositionEventsEnabled(_ value: Bool) {
    positionEvents = value
    lastPosition = .nan
    if value, isPresented { emitPosition() }
  }

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
    case "sheet-handle":
      handleChild = child
      handleObservation = child.layer.observe(\.bounds, options: [.initial, .new]) { [weak self] layer, _ in
        let height = layer.bounds.height
        DispatchQueue.main.async { self?.handleHeightChanged(height) }
      }
      (slotIfPresented(\.handleSlot) ?? self).addSubview(child)
      layoutSheet()
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
    if handleChild === child {
      handleObservation = nil
      handleChild = nil
      handleHeight = 0
      layoutSheet()
      if isPresented { emitLayout(phase: 1) }
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
    if let handle = handleChild, handle.superview !== layer.handleSlot { layer.handleSlot.addSubview(handle) }
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

  private func handleHeightChanged(_ height: CGFloat) {
    guard abs(height - handleHeight) > 0.5 else { return }
    handleHeight = height
    layoutSheet()
    guard isPresented else { return }
    if isAuto(currentIndex) {
      settleToCurrent(velocity: 0)
    } else {
      emitLayout(phase: 1)
    }
  }

  // MARK: - Commands

  @objc public func present(_ index: Int, animated: Bool) {
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
    temporaryTarget = nil
    indexBeforeKeyboard = nil
    if !wasPresented {
      visibleHeight = 0
      keyboardLift = 0
      lastEmitted = nil
      lastPosition = .nan
      layoutSheet()
      onPresent?()
    }
    if animated {
      settleToCurrent(velocity: 0)
    } else {
      animationGeneration += 1
      contentUnlocked = false
      emitLayout(phase: 0)
      visibleHeight = targetHeight()
      layoutSheet()
      contentUnlocked = atTopTarget()
      emitLayout(phase: 1)
      emitPosition()
    }
  }

  @objc public func dismiss() {
    dismiss(reason: "programmatic")
  }

  @objc public func snapTo(_ index: Int) {
    guard isPresented else { return }
    currentIndex = clampIndex(index)
    temporaryTarget = nil
    indexBeforeKeyboard = nil
    settleToCurrent(velocity: 0)
  }

  /// gorhom's `snapToPosition`: any height, expressed like one detent token.
  @objc public func snapToHeight(_ spec: String) {
    guard isPresented else { return }
    let t = spec.trimmingCharacters(in: .whitespaces)
    guard let v = Double(t), v > 0 else { return }
    let available = availableHeight()
    let height = v <= 1 ? CGFloat(v) * available : min(CGFloat(v), available)
    // The nearest detent at or below is what `index` reports meanwhile.
    let heights = resolvedHeights
    var nearest = 0
    for (i, h) in heights.enumerated() where h <= height + 0.5 { nearest = i }
    currentIndex = nearest
    temporaryTarget = height
    indexBeforeKeyboard = nil
    settleToCurrent(velocity: 0)
  }

  /// Recycled / unmounted by Fabric: tear everything down synchronously.
  @objc public func reset() {
    animationGeneration += 1
    stopDisplayLink()
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
    handleObservation = nil
    bodyChild?.removeFromSuperview()
    footerChild?.removeFromSuperview()
    handleChild?.removeFromSuperview()
    bodyChild = nil
    footerChild = nil
    handleChild = nil
    bodyAutoHeight = 0
    footerHeight = 0
    handleHeight = 0
    visibleHeight = 0
    keyboardLift = 0
    currentIndex = 0
    temporaryTarget = nil
    indexBeforeKeyboard = nil
    lastEmitted = nil
    lastPosition = .nan
  }

  private func dismiss(reason: String) {
    guard isPresented else { return }
    isPresented = false
    contentUnlocked = false
    lockObservation = nil
    lockedScrollView = nil
    dragOwner = .undecided
    dragScrollView = nil
    temporaryTarget = nil
    indexBeforeKeyboard = nil
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
  // Detents are given in the author's order but every index in the contract
  // refers to the order of their RESOLVED heights (gorhom sorts its snap
  // points the same way once a dynamic content height joins them).

  private var handleArea: CGFloat {
    if handleChild != nil { return handleHeight }
    return grabberVisible ? grabberAreaHeight : 0
  }

  private func clampIndex(_ index: Int) -> Int {
    max(0, min(index, detents.count - 1))
  }

  private func availableHeight() -> CGFloat {
    max(0, (sheetLayer?.bounds.height ?? 0) - maxDetentInset - bottomInset)
  }

  /// Height of the detent at its AUTHORED position.
  private func rawHeight(_ rawIndex: Int) -> CGFloat {
    let available = availableHeight()
    switch detents[rawIndex] {
    case .auto:
      let cap = maxAutoHeight > 0 ? min(available, maxAutoHeight) : available
      return min(cap, bodyAutoHeight + handleArea + footerHeight)
    case .fraction(let f):
      return f * available
    case .points(let p):
      return min(p, available)
    }
  }

  /// Authored indices sorted by resolved height (stable).
  private var sortedOrder: [Int] {
    let raw = detents.indices.map(rawHeight)
    return detents.indices.sorted { a, b in raw[a] == raw[b] ? a < b : raw[a] < raw[b] }
  }

  private func isAuto(_ index: Int) -> Bool {
    if case .auto = detents[sortedOrder[clampIndex(index)]] { return true }
    return false
  }

  private func resolvedHeight(_ index: Int) -> CGFloat {
    rawHeight(sortedOrder[clampIndex(index)])
  }

  /// Ascending.
  private var resolvedHeights: [CGFloat] { detents.indices.map(rawHeight).sorted() }
  /// Body height at the tallest non-auto detent; -1 when every detent is auto.
  private var maxBodyHeight: CGFloat {
    let fixed = detents.indices.filter { if case .auto = detents[$0] { return false }; return true }.map(rawHeight)
    guard let top = fixed.max() else { return -1 }
    return max(0, top - handleArea - footerHeight)
  }
  private var topHeight: CGFloat { resolvedHeights.last ?? 0 }
  private var topIndex: Int { max(0, detents.count - 1) }
  private var bottomHeight: CGFloat { resolvedHeights.first ?? 0 }
  /// Where the sheet is heading: a temporary height or the current detent.
  private func targetHeight() -> CGFloat { temporaryTarget ?? resolvedHeight(currentIndex) }
  private func atTopTarget() -> Bool { targetHeight() >= topHeight - 0.5 }

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
    layer.container.layer.maskedCorners = detached
      ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
      : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    layer.dimView.backgroundColor = dimColor
    layer.grabber.backgroundColor = grabberColor
    layer.grabber.layer.cornerRadius = grabberSize.height / 2
  }

  /// How far the whole sheet is raised by the keyboard in 'lift-sheet' mode
  /// (never past the top inset).
  private func sheetKeyboardLift() -> CGFloat {
    guard keyboardMode == "lift-sheet", keyboardLift > 0, let layer = sheetLayer else { return 0 }
    let room = layer.bounds.height - maxDetentInset - bottomInset - visibleHeight
    return max(0, min(keyboardLift, room))
  }

  /// The footer's own lift: all of the keyboard in 'lift-footer' mode; in
  /// 'lift-sheet' mode whatever the sheet itself could not rise (a sheet
  /// already at the top inset cannot move, so the footer clears the keyboard
  /// on its own — what gorhom's footer does in every keyboard behaviour).
  private func footerKeyboardLift() -> CGFloat {
    switch keyboardMode {
    case "lift-footer": return keyboardLift
    case "lift-sheet": return max(0, keyboardLift - sheetKeyboardLift())
    default: return 0
    }
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
    let margin = detached ? detachedMargin : 0
    let cw = max(0, w - 2 * margin)
    layer.container.frame = CGRect(
      x: margin, y: h - bottomInset - visibleHeight - sheetKeyboardLift(),
      width: cw, height: detached ? max(0, visibleHeight) : h + Self.overshoot)
    let area = handleArea
    layer.grabber.isHidden = !grabberVisible || handleChild != nil
    layer.grabber.frame = CGRect(
      x: (cw - grabberSize.width) / 2, y: 8,
      width: grabberSize.width, height: grabberSize.height)
    layer.handleSlot.frame = CGRect(x: 0, y: 0, width: cw, height: handleChild != nil ? handleHeight : 0)
    // Pinned to the screen's bottom edge while the sheet sits at or above its
    // lowest detent; below that (dragging to dismiss, the slide in/out) it
    // stays anchored at the lowest detent and travels with the sheet — the
    // Instagram footer.
    let anchor = max(visibleHeight, bottomHeight)
    let footerTop = max(0, anchor - footerKeyboardLift() - footerHeight)
    layer.footerSlot.frame = CGRect(x: 0, y: footerTop, width: cw, height: footerHeight)
    layer.bodySlot.frame = CGRect(x: 0, y: area, width: cw, height: max(0, footerTop - area))
    emitPosition()
  }

  fileprivate var blocksBackdropTouches: Bool { isPresented && dimmed }

  private func resolveHost() -> UIView? {
    var probe: UIView? = superview
    var nearest: UIView?
    var outermost: UIView?
    var root: UIView?
    while let view = probe {
      let name = String(describing: type(of: view))
      if name == "RNSScreenView" {
        if nearest == nil { nearest = view }
        outermost = view
      } else if name == "RCTSurfaceView" {
        // React Native's root surface view: RN's touch handler is attached
        // here, so a sheet parented to it is above every screen AND still
        // receives React touches.
        root = view
      }
      probe = view.superview
    }
    switch hostStrategy {
    case "nearest-screen": return nearest ?? outermost ?? root ?? window
    case "root": return root ?? window
    default: return outermost ?? root ?? window
    }
  }

  // MARK: - Animation

  private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

  private func settleToCurrent(velocity: CGFloat) {
    contentUnlocked = false
    emitLayout(phase: 0)
    animate(to: targetHeight(), velocity: velocity) { [weak self] finished in
      guard let self, finished, self.isPresented else { return }
      self.contentUnlocked = self.atTopTarget()
      self.emitLayout(phase: 1)
    }
  }

  private func animate(to target: CGFloat, velocity: CGFloat, completion: ((Bool) -> Void)? = nil) {
    animationGeneration += 1
    let generation = animationGeneration
    let distance = abs(target - visibleHeight)
    let springVelocity = distance > 1 ? min(abs(velocity) / distance, 12) : 0
    startDisplayLinkIfNeeded()
    let animations = {
      self.visibleHeight = target
      self.layoutSheet()
    }
    let done: (Bool) -> Void = { finished in
      guard generation == self.animationGeneration else { return }
      completion?(finished)
    }
    if reduceMotion {
      // Honour the system setting: a short fade-free ease, no spring.
      UIView.animate(
        withDuration: 0.15, delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
        animations: animations, completion: done)
      return
    }
    UIView.animate(
      withDuration: 0.5,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: springVelocity,
      options: [.allowUserInteraction, .beginFromCurrentState],
      animations: animations,
      completion: done)
  }

  /// A finger landed mid-spring: freeze the model at the presentation value.
  private func freezeAtPresentation() {
    guard let layer = sheetLayer else { return }
    if let presentation = layer.container.layer.presentation() {
      visibleHeight = max(0, layer.bounds.height - bottomInset - sheetKeyboardLift() - presentation.frame.minY)
    }
    animationGeneration += 1
    [layer.container, layer.dimView, layer.grabber, layer.handleSlot, layer.bodySlot, layer.footerSlot]
      .forEach { $0.layer.removeAllAnimations() }
    layoutSheet()
  }

  private func emitLayout(phase: Int) {
    guard isPresented else { return }
    let sheet = targetHeight()
    let dynamic = temporaryTarget == nil && isAuto(currentIndex)
    let body: CGFloat = dynamic ? -1 : max(0, sheet - handleArea - footerHeight)
    let next = Emitted(
      index: currentIndex, sheet: sheet, body: body, maxBody: maxBodyHeight,
      footer: footerHeight, keyboard: keyboardLift, host: sheetLayer?.bounds.height ?? 0,
      dynamic: dynamic ? 1 : 0, phase: phase)
    if next == lastEmitted { return }
    lastEmitted = next
    onLayoutChange?(
      next.index, next.sheet, next.body, next.maxBody, next.footer, next.keyboard, next.host, next.dynamic,
      next.phase)
  }

  // MARK: - Live position (per frame, only when armed)

  /// gorhom's fractional `animatedIndex` for a visible height.
  private func fractionalIndex(for visible: CGFloat) -> CGFloat {
    let heights = resolvedHeights
    guard let first = heights.first, first > 0 else { return visible > 0 ? 0 : -1 }
    if visible <= 0 { return -1 }
    if visible < first { return -1 + visible / first }
    for i in 0..<(heights.count - 1) {
      let lo = heights[i]
      let hi = heights[i + 1]
      if visible < hi {
        return hi > lo ? CGFloat(i) + (visible - lo) / (hi - lo) : CGFloat(i)
      }
    }
    return CGFloat(heights.count - 1)
  }

  /// Emit from the model value (drag, and the final frame of an animation).
  private func emitPosition() {
    guard positionEvents, isPresented || visibleHeight > 0, let layer = sheetLayer else { return }
    let position = layer.container.frame.minY
    emitPosition(position: position, visible: visibleHeight)
  }

  private func emitPosition(position: CGFloat, visible: CGFloat) {
    guard positionEvents else { return }
    if !lastPosition.isNaN, abs(position - lastPosition) < 0.05 { return }
    lastPosition = position
    onPositionChange?(position, fractionalIndex(for: visible), visible)
  }

  /// Inside a UIView animation the model is already at the target, so the
  /// presentation layer is sampled per frame while anything animates.
  private func startDisplayLinkIfNeeded() {
    guard positionEvents, displayLink == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @objc private func displayLinkTick() {
    guard let layer = sheetLayer, layer.superview != nil else { stopDisplayLink(); return }
    let animating = !(layer.container.layer.animationKeys()?.isEmpty ?? true)
    let minY = layer.container.layer.presentation()?.frame.minY ?? layer.container.frame.minY
    let visible = max(0, layer.bounds.height - bottomInset - sheetKeyboardLift() - minY)
    emitPosition(position: minY, visible: visible)
    if !animating { stopDisplayLink() }
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
      temporaryTarget = nil
      dragScrollView = contentPanning ? resolveScrollView() : nil
      dragInHandle = pan.location(in: layer.container).y < handleArea
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
        visibleHeight = min(visibleHeight, topHeight)
        currentIndex = topIndex
        contentUnlocked = true
        layoutSheet()
      }
      if !contentUnlocked || !contentPanning {
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

  /// gorhom's over-drag curve: the excess collapses to `sqrt(1 + excess) × factor`.
  private func resist(_ excess: CGFloat) -> CGFloat {
    (1 + max(0, excess)).squareRoot() * overDragResistance
  }

  private func applyDrag(height: CGFloat) {
    var target = height
    let top = topHeight
    let bottom = bottomHeight
    if target > top {
      // Past the top: gorhom over-drags only from the handle, or when the
      // body has no scrollable at all (a list takes the gesture instead).
      let canOverDrag = overDrag && (dragInHandle || dragScrollView == nil)
      target = canOverDrag ? top + resist(target - top) : top
    } else if target < bottom && !panToDismiss {
      target = bottom - resist(bottom - target)
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
      // The user moved the sheet by hand: a later keyboard restore would
      // fight that, so forget the pre-keyboard detent.
      indexBeforeKeyboard = nil
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
    let lowest = heights.first ?? 0
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
    temporaryTarget = nil
    settleToCurrent(velocity: -velocityY)
  }

  // MARK: - Content lock (gorhom's rule)

  /// Observe the body's scroll view so `enforceContentLock` runs on every
  /// offset write — UIKit's own tracking included. KVO fires inside the
  /// setter, before the frame is drawn, so a rejected scroll never shows.
  private func refreshContentLock() {
    guard isPresented, contentPanning, let scrollView = resolveScrollView() else {
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
    return layer.bounds.height - bottomInset - sheetKeyboardLift() - minY >= topHeight - 0.5
  }

  private func enforceContentLock(_ scrollView: UIScrollView) {
    guard !isLocking, isPresented, contentPanning else { return }
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
    // Which band the touch started in decides whether this sheet is allowed
    // to take it at all (gorhom's handle / content panning switches).
    let y = pan.location(in: layer.container).y
    let inHandle = y < handleArea
    if inHandle ? !handlePanning : !contentPanning { return false }
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

  // MARK: - Accessibility (VoiceOver drives the handle like gorhom's)

  fileprivate func accessibilityStep(_ delta: Int) {
    guard isPresented else { return }
    let next = currentIndex + delta
    if next < 0 {
      if panToDismiss { dismiss(reason: "programmatic") }
      return
    }
    snapTo(next)
  }

  // MARK: - Keyboard

  @objc private func keyboardWillChange(_ notification: Notification) {
    guard isPresented, keyboardMode != "none",
          let layer = sheetLayer, let window = layer.window,
          let info = notification.userInfo,
          let endValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
    else { return }
    let endFrame = window.convert(endValue.cgRectValue, from: nil)
    let layerBottom = layer.convert(layer.bounds, to: window).maxY - bottomInset
    // The content's own bottom padding is spent over the keyboard.
    let lift: CGFloat = notification.name == UIResponder.keyboardWillHideNotification
      ? 0 : max(0, layerBottom - endFrame.minY - contentBottomInset)
    guard abs(lift - keyboardLift) > 0.5 else { return }
    keyboardLift = lift
    if lift > 0 {
      // The keyboard opening takes the sheet to its top detent (IG comments),
      // in the same animation as the footer lift so nothing moves twice.
      if expandOnKeyboard, currentIndex != topIndex {
        if indexBeforeKeyboard == nil { indexBeforeKeyboard = currentIndex }
        currentIndex = topIndex
        temporaryTarget = nil
      }
    } else if restoreOnKeyboardHide, let before = indexBeforeKeyboard {
      // gorhom's `keyboardBlurBehavior="restore"`.
      currentIndex = clampIndex(before)
      temporaryTarget = nil
      indexBeforeKeyboard = nil
    } else {
      indexBeforeKeyboard = nil
    }
    contentUnlocked = false
    emitLayout(phase: 0)
    let target = targetHeight()
    let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    animationGeneration += 1
    let generation = animationGeneration
    startDisplayLinkIfNeeded()
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.visibleHeight = target
      self.layoutSheet()
    } completion: { finished in
      guard generation == self.animationGeneration else { return }
      if finished { self.contentUnlocked = self.atTopTarget() }
      self.emitLayout(phase: 1)
    }
  }

  // MARK: - The layer attached to the screen host

  fileprivate final class GrabberView: UIView {
    weak var owner: NativeBottomSheetContent?
    override func accessibilityIncrement() { owner?.accessibilityStep(1) }
    override func accessibilityDecrement() { owner?.accessibilityStep(-1) }
  }

  fileprivate final class SheetLayerView: UIView {
    weak var owner: NativeBottomSheetContent? {
      didSet { grabber.owner = owner }
    }
    let dimView = UIView()
    let container = UIView()
    let grabber = GrabberView()
    let handleSlot = UIView()
    let bodySlot = UIView()
    let footerSlot = UIView()

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      dimView.backgroundColor = .black
      dimView.alpha = 0
      dimView.isAccessibilityElement = true
      dimView.accessibilityLabel = "Bottom sheet backdrop"
      dimView.accessibilityHint = "Tap to close the bottom sheet"
      dimView.accessibilityTraits = .button
      addSubview(dimView)
      container.clipsToBounds = true
      container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      container.layer.cornerCurve = .continuous
      container.accessibilityLabel = "Bottom Sheet"
      addSubview(container)
      grabber.layer.cornerRadius = 2.5
      grabber.isAccessibilityElement = true
      grabber.accessibilityLabel = "Bottom sheet handle"
      grabber.accessibilityHint = "Drag up or down to extend or minimize the bottom sheet"
      grabber.accessibilityTraits = .adjustable
      container.addSubview(grabber)
      handleSlot.clipsToBounds = true
      container.addSubview(handleSlot)
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
