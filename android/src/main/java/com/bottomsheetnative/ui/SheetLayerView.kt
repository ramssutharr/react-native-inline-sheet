package com.bottomsheetnative.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import android.graphics.Outline
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.inputmethod.InputMethodManager
import android.widget.ScrollView
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedCallback
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.core.view.NestedScrollingParent3
import androidx.core.view.NestedScrollingParentHelper
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.dynamicanimation.animation.SpringAnimation
import androidx.dynamicanimation.animation.SpringForce
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.events.NativeGestureUtil
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The native sheet on Android. Counterpart of iOS `NativeBottomSheetContent`;
 * same JS contract (`NativeBottomSheetNativeComponent.ts`).
 *
 * Attached on present to the hosting screen's own view — the OUTERMOST
 * `com.swmansion.rnscreens.Screen` on the way up from the Fabric host — so it
 * covers a tab bar but sits under anything the stack pushes. Fabric never
 * lays this view out (it does not propagate descendants' requestLayout), so
 * it sizes itself to the host and re-runs its own layout pass when asked.
 *
 * Geometry (px), driven by [visible]:
 *
 *   container : laid out once at (0, 0, W, H + overshoot); moved with
 *               `translationY = H - visible` so no layout pass runs per frame
 *   bodySlot  : (0, grabberArea, W, footerTop) inside the container, clips
 *   footerSlot: (0, footerTop, W, footerTop + footerH) with
 *               footerTop = visible - keyboardLift - footerH
 *   dim       : layer bounds, alpha = dimOpacity * min(1, visible / detent0)
 *
 * The RN body/footer children are re-parented into the slots and NEVER
 * measured or laid out here — Fabric drives their frames (an UNSPECIFIED
 * measure from us would abort with "A catalyst view must have an explicit
 * width and height"); the slots only clip and move.
 *
 * Hand-rolled on purpose (no Material BottomSheetBehavior): identical px /
 * N-detent physics to iOS, explicit choice of the scrolling child, and a
 * single IME path that does not depend on `adjustResize` (edge-to-edge
 * windows do not resize).
 */
class SheetLayerView(
    context: Context,
    private val owner: NativeBottomSheetHostView,
) : ViewGroup(context), NestedScrollingParent3 {

    private sealed class Detent {
        object Auto : Detent()
        data class Fraction(val value: Float) : Detent()
        data class Points(val px: Float) : Detent()
    }

    // MARK: - Configuration (px)

    private var detents: List<Detent> = listOf(Detent.Auto)
    private var initialDetent = 0
    private var maxDetentInset = 0f
    private var bottomInset = 0f
    private var dimmed = true
    private var dimOpacity = 0.5f
    private var dimColor = Color.BLACK
    private var cornerRadius = dp(24f)
    private var grabberVisible = true
    private var grabberAreaHeight = dp(22f)
    private var sheetBackgroundColor = Color.WHITE
    private var grabberColor = 0x80808080.toInt()
    private var grabberWidth = dp(36f).roundToInt()
    private var grabberHeight = dp(5f).roundToInt()
    private var panToDismiss = true
    private var dismissOnBackdrop = true
    private var keyboardMode = "lift-footer"
    private var expandOnKeyboard = true
    private var dismissKeyboardOnDrag = true
    private var hostStrategy = "outermost-screen"

    // MARK: - Views

    private val dim = View(context).apply {
        setBackgroundColor(Color.BLACK)
        alpha = 0f
        isClickable = true
        setOnClickListener { onBackdropTap() }
    }
    private val container = SheetContainer(context)
    private val background = GradientDrawable()
    private val grabber = View(context)
    private val grabberDrawable = GradientDrawable()
    private val bodySlot = SlotView(context)
    private val footerSlot = SlotView(context)

    // MARK: - React children

    private var bodyChild: View? = null
    private var footerChild: View? = null
    private var bodyAutoHeight = 0f
    private var footerHeight = 0f
    private val bodyLayoutListener = View.OnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ ->
        bodyHeightChanged((bottom - top).toFloat())
    }
    private val footerLayoutListener = View.OnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ ->
        footerHeightChanged((bottom - top).toFloat())
    }

    // MARK: - State

    private var presented = false
    private var currentIndex = 0
    private var visible = 0f
    private var keyboardLift = 0f
    private var hostView: ViewGroup? = null
    private var springAnim: SpringAnimation? = null
    private var backCallback: OnBackPressedCallback? = null
    private var dragEmittedStart = false

    private data class Emitted(
        val index: Int, val sheet: Float, val body: Float, val maxBody: Float,
        val footer: Float, val keyboard: Float, val phase: Int,
    )
    private var lastEmitted: Emitted? = null

    private val overshoot = dp(240f).roundToInt()
    private val grabberTop = dp(8f).roundToInt()

    private val hostLayoutListener = View.OnLayoutChangeListener { _, l, t, r, b, ol, ot, or, ob ->
        if (r - l != or - ol || b - t != ob - ot) selfLayout()
    }

    private var layoutPassScheduled = false
    private val selfLayoutRunnable = Runnable {
        layoutPassScheduled = false
        selfLayout()
    }

    init {
        clipChildren = false
        addView(dim)
        addView(container)
        container.addView(grabber)
        container.addView(bodySlot)
        container.addView(footerSlot)
        grabber.background = grabberDrawable
        container.background = background
        applyChrome()

        // Edge-to-edge (targetSdk 36): the window does not resize for the
        // keyboard, so the footer is lifted by the IME inset. The animation
        // callback gives the smooth lift; the plain listener + a read of the
        // ROOT window insets is the fallback when RN's root has already
        // consumed the dispatch (it does — a listener on this view alone
        // sees zeroes).
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            refreshInsets()
            insets
        }
        ViewCompat.setWindowInsetsAnimationCallback(
            this,
            object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(
                    insets: WindowInsetsCompat,
                    runningAnimations: MutableList<WindowInsetsAnimationCompat>,
                ): WindowInsetsCompat {
                    if (runningAnimations.any { it.typeMask and WindowInsetsCompat.Type.ime() != 0 }) {
                        applyIme(insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
                    }
                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimationCompat) {
                    if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) {
                        refreshInsets()
                        emitLayout(1)
                    }
                }
            },
        )
    }

    // MARK: - Props

    fun setDetentsSpec(spec: String) {
        val parsed = spec.split(',').mapNotNull { token ->
            val t = token.trim()
            if (t == "auto") return@mapNotNull Detent.Auto
            val v = t.toFloatOrNull() ?: return@mapNotNull null
            if (v <= 0f) return@mapNotNull null
            if (v <= 1f) Detent.Fraction(v) else Detent.Points(dp(v))
        }
        detents = if (parsed.isEmpty()) listOf(Detent.Auto) else parsed
    }

    fun setInitialDetent(index: Int) { initialDetent = index }
    fun setMaxDetentInsetDp(value: Float) { maxDetentInset = dp(value) }
    fun setBottomInsetDp(value: Float) { bottomInset = dp(value) }
    fun setDimColor(color: Int?) { dimColor = color ?: Color.BLACK }
    fun setGrabberWidthDp(value: Float) { grabberWidth = dp(value).roundToInt() }
    fun setGrabberHeightDp(value: Float) { grabberHeight = dp(value).roundToInt() }
    fun setDimmed(value: Boolean) { dimmed = value }
    fun setDimOpacity(value: Float) { dimOpacity = value }
    fun setCornerRadiusDp(value: Float) { cornerRadius = dp(value) }
    fun setGrabber(value: Boolean) { grabberVisible = value }
    fun setGrabberAreaHeightDp(value: Float) { grabberAreaHeight = dp(value) }
    fun setSheetBackgroundColor(color: Int?) { sheetBackgroundColor = color ?: Color.WHITE }
    fun setGrabberColor(color: Int?) { grabberColor = color ?: 0x80808080.toInt() }
    fun setEnablePanToDismiss(value: Boolean) { panToDismiss = value }
    fun setDismissOnBackdropPress(value: Boolean) { dismissOnBackdrop = value }
    fun setKeyboardMode(value: String) { keyboardMode = value }
    fun setExpandOnKeyboard(value: Boolean) { expandOnKeyboard = value }
    fun setDismissKeyboardOnDrag(value: Boolean) { dismissKeyboardOnDrag = value }
    fun setHostStrategy(value: String) { hostStrategy = value }

    /** After every prop of a commit: re-resolve, since detents read the inset and grabber area. */
    fun onPropsApplied() {
        applyChrome()
        if (!presented) return
        currentIndex = clampIndex(currentIndex)
        layoutSheet()
        settleToCurrent(0f)
    }

    private fun applyChrome() {
        background.setColor(sheetBackgroundColor)
        background.cornerRadii = floatArrayOf(
            cornerRadius, cornerRadius, cornerRadius, cornerRadius, 0f, 0f, 0f, 0f,
        )
        grabberDrawable.setColor(grabberColor)
        grabberDrawable.cornerRadius = grabberHeight / 2f
        dim.setBackgroundColor(dimColor)
        container.invalidateOutline()
        grabber.visibility = if (grabberVisible) VISIBLE else GONE
        dim.visibility = if (dimmed) VISIBLE else GONE
    }

    // MARK: - React children

    fun attachChild(child: View, nativeId: String?) {
        when (nativeId) {
            "sheet-body" -> {
                bodyChild = child
                child.addOnLayoutChangeListener(bodyLayoutListener)
                moveTo(child, if (isAttachedToHost()) bodySlot else null)
                bodyHeightChanged(child.height.toFloat())
            }
            "sheet-footer" -> {
                footerChild = child
                child.addOnLayoutChangeListener(footerLayoutListener)
                moveTo(child, if (isAttachedToHost()) footerSlot else null)
                footerHeightChanged(child.height.toFloat())
            }
            else -> moveTo(child, null)
        }
    }

    fun detachChild(child: View) {
        if (bodyChild === child) {
            child.removeOnLayoutChangeListener(bodyLayoutListener)
            bodyChild = null
            bodyAutoHeight = 0f
        }
        if (footerChild === child) {
            child.removeOnLayoutChangeListener(footerLayoutListener)
            footerChild = null
            footerHeight = 0f
            layoutSlots()
        }
        (child.parent as? ViewGroup)?.removeView(child)
    }

    /** null = park in the (hidden) Fabric host. */
    private fun moveTo(child: View, slot: ViewGroup?) {
        if (slot == null) {
            owner.park(child)
            return
        }
        if (child.parent === slot) return
        (child.parent as? ViewGroup)?.removeView(child)
        slot.addView(child)
    }

    private fun attachChildrenToSlots() {
        bodyChild?.let { moveTo(it, bodySlot) }
        footerChild?.let { moveTo(it, footerSlot) }
    }

    private fun bodyHeightChanged(height: Float) {
        if (abs(height - bodyAutoHeight) < 0.5f) return
        bodyAutoHeight = height
        if (!presented || !isAuto(currentIndex)) return
        settleToCurrent(0f)
    }

    private fun footerHeightChanged(height: Float) {
        if (abs(height - footerHeight) < 0.5f) return
        footerHeight = height
        layoutSlots()
        if (!presented) return
        if (isAuto(currentIndex)) settleToCurrent(0f) else emitLayout(1)
    }

    // MARK: - Commands

    fun present(index: Int) {
        val host = resolveHost() ?: return
        if (parent !== host) {
            (parent as? ViewGroup)?.removeView(this)
            // Appended LAST: the screen's own RN children are addressed by
            // index, so anything of ours must stay after them.
            host.addView(this, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        } else {
            host.bringChildToFront(this)
        }
        if (hostView !== host) {
            hostView?.removeOnLayoutChangeListener(hostLayoutListener)
            hostView = host
            host.addOnLayoutChangeListener(hostLayoutListener)
        }
        selfLayout()
        attachChildrenToSlots()

        val wasPresented = presented
        presented = true
        currentIndex = clampIndex(index)
        if (!wasPresented) {
            visible = 0f
            keyboardLift = 0f
            lastEmitted = null
            layoutSheet()
            installBack()
            refreshInsets()
            owner.onPresent?.invoke()
        }
        settleToCurrent(0f)
    }

    fun snapTo(index: Int) {
        if (!presented) return
        currentIndex = clampIndex(index)
        settleToCurrent(0f)
    }

    fun dismiss(reason: String) {
        if (!presented) return
        presented = false
        container.abortDrag()
        uninstallBack()
        if (dragEmittedStart) {
            dragEmittedStart = false
            owner.onDragEnd?.invoke()
        }
        settle(0f, 0f) {
            if (presented) return@settle
            detachFromHost()
            keyboardLift = 0f
            lastEmitted = null
            // AFTER the slide-out so JS keeps the content mounted until the
            // sheet is actually gone.
            owner.onDismiss?.invoke(reason)
        }
    }

    /** Fabric dropped the host: tear down synchronously. */
    fun destroy() {
        cancelSpring()
        container.abortDrag()
        uninstallBack()
        if (presented) {
            presented = false
            owner.onDismiss?.invoke("unmounted")
        }
        detachFromHost()
        bodyChild?.let { it.removeOnLayoutChangeListener(bodyLayoutListener); (it.parent as? ViewGroup)?.removeView(it) }
        footerChild?.let { it.removeOnLayoutChangeListener(footerLayoutListener); (it.parent as? ViewGroup)?.removeView(it) }
        bodyChild = null
        footerChild = null
        bodyAutoHeight = 0f
        footerHeight = 0f
        visible = 0f
        keyboardLift = 0f
        currentIndex = 0
        lastEmitted = null
    }

    private fun detachFromHost() {
        hostView?.removeOnLayoutChangeListener(hostLayoutListener)
        hostView = null
        (parent as? ViewGroup)?.removeView(this)
    }

    private fun isAttachedToHost(): Boolean = parent != null

    // MARK: - Host resolution

    private fun resolveHost(): ViewGroup? {
        var probe = owner.parent
        var nearest: ViewGroup? = null
        var outermost: ViewGroup? = null
        while (probe != null) {
            if (probe::class.java.name == "com.swmansion.rnscreens.Screen") {
                if (nearest == null) nearest = probe as? ViewGroup
                outermost = probe as? ViewGroup
            }
            probe = probe.parent
        }
        val chosen = if (hostStrategy == "nearest-screen") nearest else outermost
        return chosen ?: activity()?.findViewById(android.R.id.content)
    }

    /**
     * `ThemedReactContext` does NOT wrap the Activity — walking its
     * ContextWrapper chain lands on the Application and silently returns
     * nothing. `currentActivity` is the reliable route.
     */
    private fun activity(): Activity? =
        (context as? ThemedReactContext)?.currentActivity
            ?: generateSequence(context) { (it as? ContextWrapper)?.baseContext }
                .filterIsInstance<Activity>()
                .firstOrNull()

    // MARK: - Detents

    private val grabberArea: Float get() = if (grabberVisible) grabberAreaHeight else 0f

    private fun clampIndex(index: Int): Int = index.coerceIn(0, detents.size - 1)

    private fun isAuto(index: Int): Boolean = detents[clampIndex(index)] is Detent.Auto

    private fun availableHeight(): Float = max(0f, height - maxDetentInset - bottomInset)

    private fun resolvedHeight(index: Int): Float {
        val available = availableHeight()
        return when (val d = detents[clampIndex(index)]) {
            is Detent.Auto -> min(available, bodyAutoHeight + grabberArea + footerHeight)
            is Detent.Fraction -> d.value * available
            is Detent.Points -> min(d.px, available)
        }
    }

    private fun resolvedHeights(): List<Float> = detents.indices.map { resolvedHeight(it) }

    /** Body height at the tallest non-auto detent; -1 when every detent is auto. */
    private fun maxBodyHeight(): Float {
        val top = detents.indices.filter { !isAuto(it) }.map { resolvedHeight(it) }.maxOrNull() ?: return -1f
        return max(0f, top - grabberArea - footerHeight)
    }
    private fun topHeight(): Float = resolvedHeights().maxOrNull() ?: 0f
    private fun topIndex(): Int {
        val heights = resolvedHeights()
        val top = heights.maxOrNull() ?: return 0
        return heights.indexOf(top).coerceAtLeast(0)
    }
    private fun bottomHeight(): Float = resolvedHeights().minOrNull() ?: 0f
    private fun atDetent(): Boolean = resolvedHeights().any { abs(it - visible) < 1f }

    // MARK: - Layout (self-driven; Fabric never lays this view out)

    override fun requestLayout() {
        super.requestLayout()
        if (layoutPassScheduled) return
        layoutPassScheduled = true
        post(selfLayoutRunnable)
    }

    private fun selfLayout() {
        val host = hostView ?: return
        val w = host.width
        val h = host.height
        if (w == 0 || h == 0) return
        measure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY),
        )
        layout(0, 0, w, h)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(w, h)
        dim.measure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY),
        )
        container.measure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(h + overshoot, MeasureSpec.EXACTLY),
        )
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        layoutSheet()
    }

    private fun layoutSheet() {
        val w = width
        val h = height
        if (w == 0 || h == 0) return
        dim.layout(0, 0, w, h)
        container.layout(0, 0, w, h + overshoot)
        applyVisible()
    }

    /** Whole-sheet rise in 'lift-sheet' keyboard mode (never past the top inset). */
    private fun sheetKeyboardLift(): Float {
        if (keyboardMode != "lift-sheet" || keyboardLift <= 0f) return 0f
        val room = height - maxDetentInset - bottomInset - visible
        return max(0f, min(keyboardLift, room))
    }

    private fun footerKeyboardLift(): Float = if (keyboardMode == "lift-footer") keyboardLift else 0f

    /** Everything that depends on [visible]: translation, dim, slots. */
    private fun applyVisible() {
        val h = height
        if (h == 0) return
        // `bottomInset` lifts the resting bottom edge (above a tab bar, say).
        container.translationY = h - bottomInset - visible - sheetKeyboardLift()
        val first = resolvedHeight(0)
        val progress = if (first > 0f) (visible / first).coerceIn(0f, 1f) else 1f
        dim.alpha = if (dimmed) dimOpacity * progress else 0f
        layoutSlots()
    }

    private fun layoutSlots() {
        val w = container.width
        if (w == 0) return
        val gx = (w - grabberWidth) / 2
        grabber.measure(
            MeasureSpec.makeMeasureSpec(grabberWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(grabberHeight, MeasureSpec.EXACTLY),
        )
        grabber.layout(gx, grabberTop, gx + grabberWidth, grabberTop + grabberHeight)

        val footerH = footerHeight.roundToInt()
        // Pinned to the screen's bottom edge while the sheet sits at or above
        // its lowest detent; below that (dragging to dismiss, the slide
        // in/out) it stays anchored at the lowest detent and travels with the
        // sheet — the Instagram footer.
        val anchor = max(visible, bottomHeight())
        val footerTop = max(0f, anchor - footerKeyboardLift() - footerHeight).roundToInt()
        footerSlot.measure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(footerH, MeasureSpec.EXACTLY),
        )
        footerSlot.layout(0, footerTop, w, footerTop + footerH)

        val bodyTop = grabberArea.roundToInt()
        val bodyBottom = max(bodyTop, footerTop)
        bodySlot.measure(
            MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(bodyBottom - bodyTop, MeasureSpec.EXACTLY),
        )
        bodySlot.layout(0, bodyTop, w, bodyBottom)
    }

    private fun setVisibleRaw(value: Float) {
        visible = max(0f, value)
        applyVisible()
    }

    // MARK: - Animation

    private val visibleProperty = object : FloatPropertyCompat<SheetLayerView>("visible") {
        override fun getValue(o: SheetLayerView): Float = o.visible
        override fun setValue(o: SheetLayerView, value: Float) = o.setVisibleRaw(value)
    }

    private fun settleToCurrent(velocity: Float) {
        emitLayout(0)
        settle(resolvedHeight(currentIndex), velocity) {
            if (presented) emitLayout(1)
        }
    }

    private fun settle(target: Float, velocity: Float, onEnd: (() -> Unit)? = null) {
        cancelSpring()
        val anim = SpringAnimation(this, visibleProperty).apply {
            spring = SpringForce(target).setStiffness(650f).setDampingRatio(0.86f)
            setStartVelocity(velocity)
            minimumVisibleChange = 0.5f
        }
        anim.addEndListener { _, canceled, _, _ ->
            if (springAnim === anim) springAnim = null
            if (!canceled) {
                setVisibleRaw(target)
                onEnd?.invoke()
            }
        }
        springAnim = anim
        anim.start()
    }

    private fun cancelSpring() {
        springAnim?.cancel()
        springAnim = null
    }

    // MARK: - Drag (shared by the container's touch path and nested scrolling)

    private fun applyDrag(height: Float) {
        var target = height
        val top = topHeight()
        val bottom = bottomHeight()
        if (target > top) {
            // Hard stop at the top detent (IG / gorhom), no rubber band.
            target = top
        } else if (target < bottom && !panToDismiss) {
            target = bottom - (bottom - target) * 0.2f
        }
        setVisibleRaw(target)
    }

    /** [velocity] in px/s of [visible] (positive = growing). */
    private fun settleFromRelease(velocity: Float) {
        val heights = resolvedHeights()
        if (heights.isEmpty()) return
        val projected = visible + velocity * 0.12f
        val lowest = heights.minOrNull() ?: 0f
        val flickDown = velocity < -dp(1500f) && visible <= lowest + 1f
        if (panToDismiss && (projected < lowest * 0.5f || flickDown)) {
            dismiss("drag")
            return
        }
        var best = 0
        var bestDistance = Float.MAX_VALUE
        heights.forEachIndexed { index, h ->
            val d = abs(h - projected)
            if (d < bestDistance) {
                bestDistance = d
                best = index
            }
        }
        currentIndex = best
        settleToCurrent(velocity)
    }

    private fun emitDragStart() {
        if (dragEmittedStart) return
        dragEmittedStart = true
        if (dismissKeyboardOnDrag && keyboardLift > 0f) hideKeyboard()
        owner.onDragStart?.invoke()
    }

    /** Hide the IME and blur the focused input so RN sees a real blur. */
    private fun hideKeyboard() {
        val focused = findFocus() ?: activity()?.currentFocus
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        imm?.hideSoftInputFromWindow((focused ?: this).windowToken, 0)
        focused?.clearFocus()
    }

    private fun emitDragEnd() {
        if (!dragEmittedStart) return
        dragEmittedStart = false
        owner.onDragEnd?.invoke()
    }

    private fun emitLayout(phase: Int) {
        if (!presented) return
        val sheet = resolvedHeight(currentIndex)
        val body = if (isAuto(currentIndex)) -1f else max(0f, sheet - grabberArea - footerHeight)
        val next = Emitted(currentIndex, sheet, body, maxBodyHeight(), footerHeight, keyboardLift, phase)
        if (next == lastEmitted) return
        lastEmitted = next
        owner.onLayoutChange?.invoke(
            next.index,
            px(next.sheet),
            if (next.body < 0f) -1f else px(next.body),
            if (next.maxBody < 0f) -1f else px(next.maxBody),
            px(next.footer),
            px(next.keyboard),
            next.phase,
        )
    }

    // MARK: - Backdrop / back / keyboard

    private fun onBackdropTap() {
        if (!dismissOnBackdrop) return
        dismiss("backdrop")
    }

    private fun installBack() {
        uninstallBack()
        val dispatcherOwner = activity() as? OnBackPressedDispatcherOwner ?: return
        val callback = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                dismiss("back")
            }

            override fun handleOnBackProgressed(backEvent: BackEventCompat) {
                if (Build.VERSION.SDK_INT < 34) return
                cancelSpring()
                setVisibleRaw(resolvedHeight(currentIndex) * (1f - 0.12f * backEvent.progress))
            }

            override fun handleOnBackCancelled() {
                settleToCurrent(0f)
            }
        }
        backCallback = callback
        dispatcherOwner.onBackPressedDispatcher.addCallback(callback)
    }

    private fun uninstallBack() {
        backCallback?.remove()
        backCallback = null
    }

    private fun refreshInsets() {
        val insets = ViewCompat.getRootWindowInsets(this) ?: return
        applyIme(insets.getInsets(WindowInsetsCompat.Type.ime()).bottom)
    }

    /** The IME inset is measured from the window's bottom edge — used as-is. */
    private fun applyIme(bottomPx: Int) {
        if (keyboardMode == "none") return
        val lift = max(0f, bottomPx - bottomInset)
        if (lift == keyboardLift) return
        keyboardLift = lift
        // 'lift-sheet' moves the container, 'lift-footer' only the footer slot.
        applyVisible()
        // The keyboard opening takes the sheet to its top detent (IG
        // comments); the spring runs alongside the IME's own animation.
        if (lift > 0 && presented && expandOnKeyboard && currentIndex != topIndex()) {
            currentIndex = topIndex()
            settleToCurrent(0f)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        refreshInsets()
    }

    // MARK: - NestedScrollingParent3 (the list ↔ sheet hand-off)
    // ReactScrollView dispatches nested pre-scroll on every touch move once
    // `nestedScrollEnabled` is set. dy > 0 = finger moving up.

    private val nestedHelper = NestedScrollingParentHelper(this)
    private var nestedDragging = false
    private var nestedFlung = false
    /**
     * Gorhom's rule: a gesture that starts (or takes over) while the sheet is
     * below its top detent belongs to the sheet until the finger lifts — the
     * list stays at offset 0 even after the sheet reaches the top. Content
     * scrolls only in a gesture that BEGAN with the sheet fully expanded.
     */
    private var nestedLockContent = false

    override fun onStartNestedScroll(child: View, target: View, axes: Int, type: Int): Boolean =
        (axes and ViewCompat.SCROLL_AXIS_VERTICAL) != 0 && type == ViewCompat.TYPE_TOUCH

    override fun onNestedScrollAccepted(child: View, target: View, axes: Int, type: Int) {
        nestedHelper.onNestedScrollAccepted(child, target, axes, type)
        cancelSpring()
        nestedDragging = false
        nestedFlung = false
        nestedLockContent = visible < topHeight() - 0.5f
    }

    override fun onStopNestedScroll(target: View, type: Int) {
        nestedHelper.onStopNestedScroll(target, type)
        nestedLockContent = false
        if (!nestedDragging) return
        nestedDragging = false
        if (!nestedFlung) settleFromRelease(0f)
        nestedFlung = false
        emitDragEnd()
    }

    override fun onNestedPreScroll(target: View, dx: Int, dy: Int, consumed: IntArray, type: Int) {
        if (type != ViewCompat.TYPE_TOUCH || !presented) return
        if (nestedLockContent) {
            markNestedDragging()
            if (dy > 0) {
                // Pushing up: the sheet takes what it needs to reach the top;
                // once there, the lock releases and the REST of this same
                // gesture scrolls the list.
                val top = topHeight()
                val take = min(dy.toFloat(), max(0f, top - visible))
                if (take > 0f) setVisibleRaw(visible + take)
                consumed[1] = take.roundToInt()
                if (visible >= top - 0.5f) {
                    currentIndex = topIndex()
                    nestedLockContent = false
                }
            } else {
                // Pulling down: every pixel moves the sheet, none reaches the list.
                applyDrag(visible + dy)
                consumed[1] = dy
            }
            return
        }
        // Sheet fully expanded: the list scrolls, except that pulling down at
        // its top hands the gesture to the sheet for good.
        if (dy < 0 && !target.canScrollVertically(-1)) {
            nestedLockContent = true
            applyDrag(visible + dy)
            consumed[1] = dy
            markNestedDragging()
        }
    }

    override fun onNestedScroll(
        target: View, dxConsumed: Int, dyConsumed: Int, dxUnconsumed: Int, dyUnconsumed: Int,
        type: Int, consumed: IntArray,
    ) = Unit

    override fun onNestedScroll(
        target: View, dxConsumed: Int, dyConsumed: Int, dxUnconsumed: Int, dyUnconsumed: Int, type: Int,
    ) = Unit

    override fun onNestedPreFling(target: View, velocityX: Float, velocityY: Float): Boolean {
        if (nestedLockContent) {
            // The list never flings from a sheet-owned gesture; the sheet
            // settles with the release velocity instead.
            // velocityY > 0 = content flinging down = finger moved up = sheet grows.
            nestedFlung = true
            settleFromRelease(velocityY)
            return true
        }
        return false
    }

    override fun onNestedFling(target: View, velocityX: Float, velocityY: Float, consumed: Boolean): Boolean = false

    // NestedScrollingParent (v1) — routed to the typed variants.
    override fun onStartNestedScroll(child: View, target: View, axes: Int): Boolean =
        onStartNestedScroll(child, target, axes, ViewCompat.TYPE_TOUCH)

    override fun onNestedScrollAccepted(child: View, target: View, axes: Int) =
        onNestedScrollAccepted(child, target, axes, ViewCompat.TYPE_TOUCH)

    override fun onStopNestedScroll(target: View) = onStopNestedScroll(target, ViewCompat.TYPE_TOUCH)

    override fun onNestedScroll(target: View, dxConsumed: Int, dyConsumed: Int, dxUnconsumed: Int, dyUnconsumed: Int) =
        onNestedScroll(target, dxConsumed, dyConsumed, dxUnconsumed, dyUnconsumed, ViewCompat.TYPE_TOUCH)

    override fun onNestedPreScroll(target: View, dx: Int, dy: Int, consumed: IntArray) =
        onNestedPreScroll(target, dx, dy, consumed, ViewCompat.TYPE_TOUCH)

    override fun getNestedScrollAxes(): Int = nestedHelper.nestedScrollAxes

    private fun markNestedDragging() {
        if (nestedDragging) return
        nestedDragging = true
        emitDragStart()
    }

    // MARK: - dp helpers

    private fun dp(value: Float): Float = PixelUtil.toPixelFromDIP(value)
    private fun px(value: Float): Float = PixelUtil.toDIPFromPixel(value)

    // MARK: - The sheet container: chrome + the direct-touch drag path

    private inner class SheetContainer(context: Context) : ViewGroup(context) {
        private val slop = ViewConfiguration.get(context).scaledTouchSlop
        private var tracker: VelocityTracker? = null
        private var downRawX = 0f
        private var downRawY = 0f
        private var dragAnchorRawY = 0f
        private var dragStartVisible = 0f
        private var dragging = false
        private var touchOnScrollable = false

        init {
            clipChildren = true
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    // Bottom corners live in the off-screen overshoot, so a
                    // uniform radius reads as top-only.
                    outline.setRoundRect(0, 0, view.width, view.height, cornerRadius)
                }
            }
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            layoutSlots()
        }

        fun abortDrag() {
            dragging = false
            touchOnScrollable = false
            tracker?.recycle()
            tracker = null
        }

        // Touches that start on a nested-scrolling list are left alone — the
        // hand-off for those rides on NestedScrollingParent3. Everything else
        // (grabber, header rows, the footer) is dragged directly.
        override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = ev.rawX
                    downRawY = ev.rawY
                    dragging = false
                    cancelSpring()
                    touchOnScrollable = findNestedScrollableUnder(this, ev.x, ev.y) != null
                    tracker?.recycle()
                    tracker = VelocityTracker.obtain().also { it.addMovement(ev) }
                }
                MotionEvent.ACTION_MOVE -> {
                    tracker?.addMovement(ev)
                    if (touchOnScrollable || !presented) return false
                    val dy = ev.rawY - downRawY
                    val dx = ev.rawX - downRawX
                    if (!dragging && abs(dy) > slop && abs(dy) > abs(dx)) {
                        beginDrag(ev)
                        return true
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    tracker?.recycle()
                    tracker = null
                }
            }
            return false
        }

        override fun onTouchEvent(ev: MotionEvent): Boolean {
            (tracker ?: VelocityTracker.obtain().also { tracker = it }).addMovement(ev)
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = ev.rawX
                    downRawY = ev.rawY
                    dragging = false
                    touchOnScrollable = false
                    cancelSpring()
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!presented) return true
                    if (!dragging) {
                        val dy = ev.rawY - downRawY
                        val dx = ev.rawX - downRawX
                        if (abs(dy) > slop && abs(dy) > abs(dx)) beginDrag(ev)
                    }
                    if (dragging) applyDrag(dragStartVisible - (ev.rawY - dragAnchorRawY))
                }
                MotionEvent.ACTION_UP -> {
                    if (dragging) {
                        val t = tracker
                        t?.computeCurrentVelocity(1000)
                        val fingerVelocity = t?.yVelocity ?: 0f
                        NativeGestureUtil.notifyNativeGestureEnded(this, ev)
                        endDrag(-fingerVelocity)
                    }
                    tracker?.recycle()
                    tracker = null
                }
                MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        NativeGestureUtil.notifyNativeGestureEnded(this, ev)
                        endDrag(0f)
                    }
                    tracker?.recycle()
                    tracker = null
                }
            }
            return true
        }

        private fun beginDrag(ev: MotionEvent) {
            dragging = true
            dragAnchorRawY = ev.rawY
            dragStartVisible = visible
            parent?.requestDisallowInterceptTouchEvent(true)
            // React's JS touch is still live under the finger: cancel it so a
            // Pressable does not fire on release (what ReactScrollView does
            // when its own drag begins).
            NativeGestureUtil.notifyNativeGestureStarted(this, ev)
            emitDragStart()
        }

        private fun endDrag(velocity: Float) {
            dragging = false
            settleFromRelease(velocity)
            emitDragEnd()
        }

        private fun findNestedScrollableUnder(group: ViewGroup, x: Float, y: Float): View? {
            for (i in group.childCount - 1 downTo 0) {
                val child = group.getChildAt(i)
                if (child.visibility != VISIBLE) continue
                val cx = x + group.scrollX - child.left - child.translationX
                val cy = y + group.scrollY - child.top - child.translationY
                if (cx < 0f || cy < 0f || cx > child.width || cy > child.height) continue
                if (ViewCompat.isNestedScrollingEnabled(child) &&
                    (child is ScrollView || child.canScrollVertically(1) || child.canScrollVertically(-1))
                ) {
                    return child
                }
                if (child is ViewGroup) {
                    findNestedScrollableUnder(child, cx, cy)?.let { return it }
                }
            }
            return null
        }
    }

    /** A slot only clips and moves; the RN child inside is Fabric's to size. */
    private class SlotView(context: Context) : ViewGroup(context) {
        init {
            clipChildren = true
            clipToPadding = true
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), MeasureSpec.getSize(heightMeasureSpec))
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) = Unit
    }
}
