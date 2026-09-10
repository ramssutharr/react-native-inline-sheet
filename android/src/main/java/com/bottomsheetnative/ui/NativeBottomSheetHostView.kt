package com.bottomsheetnative.ui

import android.content.Context
import android.view.View
import android.view.ViewGroup
import com.facebook.react.R

/**
 * The Fabric host: a hidden, zero-size parking lot for the React children
 * Fabric mounts under the component. On present the [SheetLayerView] moves
 * them into its slots; the ViewManager's virtual child ops keep describing
 * them here so Fabric can still find and unmount them wherever they live.
 */
class NativeBottomSheetHostView(context: Context) : ViewGroup(context) {

    var onPresent: (() -> Unit)? = null
    var onDismiss: ((String) -> Unit)? = null
    var onDragStart: (() -> Unit)? = null
    var onDragEnd: (() -> Unit)? = null
    /** (index, sheetHeight, bodyHeight (-1 = auto), maxBodyHeight (-1 = all auto), footerHeight, keyboardHeight, phase) — dp. */
    var onLayoutChange: ((Int, Float, Float, Float, Float, Float, Int) -> Unit)? = null

    private val reactChildren = ArrayList<View>()
    internal val sheet = SheetLayerView(context, this)

    init {
        visibility = INVISIBLE
        setWillNotDraw(true)
        clipChildren = true
    }

    // Fabric sizes this view (0×0 from JS); never lay out RN children here.
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(
            MeasureSpec.getSize(widthMeasureSpec),
            MeasureSpec.getSize(heightMeasureSpec),
        )
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) = Unit

    // MARK: - Props (dp in, converted by the sheet)

    fun setDetentsSpec(spec: String) = sheet.setDetentsSpec(spec)
    fun setInitialDetent(index: Int) = sheet.setInitialDetent(index)
    fun setMaxDetentInsetDp(value: Float) = sheet.setMaxDetentInsetDp(value)
    fun setBottomInsetDp(value: Float) = sheet.setBottomInsetDp(value)
    fun setDimColor(color: Int?) = sheet.setDimColor(color)
    fun setGrabberWidthDp(value: Float) = sheet.setGrabberWidthDp(value)
    fun setGrabberHeightDp(value: Float) = sheet.setGrabberHeightDp(value)
    fun setDimmed(value: Boolean) = sheet.setDimmed(value)
    fun setDimOpacity(value: Float) = sheet.setDimOpacity(value)
    fun setCornerRadiusDp(value: Float) = sheet.setCornerRadiusDp(value)
    fun setGrabber(value: Boolean) = sheet.setGrabber(value)
    fun setGrabberAreaHeightDp(value: Float) = sheet.setGrabberAreaHeightDp(value)
    fun setSheetBackgroundColor(color: Int?) = sheet.setSheetBackgroundColor(color)
    fun setGrabberColor(color: Int?) = sheet.setGrabberColor(color)
    fun setEnablePanToDismiss(value: Boolean) = sheet.setEnablePanToDismiss(value)
    fun setDismissOnBackdropPress(value: Boolean) = sheet.setDismissOnBackdropPress(value)
    fun setKeyboardMode(value: String) = sheet.setKeyboardMode(value)
    fun setExpandOnKeyboard(value: Boolean) = sheet.setExpandOnKeyboard(value)
    fun setDismissKeyboardOnDrag(value: Boolean) = sheet.setDismissKeyboardOnDrag(value)
    fun setHostStrategy(value: String) = sheet.setHostStrategy(value)

    fun onPropsApplied() = sheet.onPropsApplied()

    // MARK: - Commands

    fun present(index: Int) = sheet.present(index)
    fun dismiss() = sheet.dismiss("programmatic")
    fun snapTo(index: Int) = sheet.snapTo(index)

    /** Fabric dropped the view: tear the sheet down synchronously. */
    fun onDropped() = sheet.destroy()

    // MARK: - RN children (virtual list for the ViewManager)

    fun mountReactChild(child: View, index: Int) {
        val at = index.coerceIn(0, reactChildren.size)
        reactChildren.add(at, child)
        val nativeId = child.getTag(R.id.view_tag_native_id) as? String
        sheet.attachChild(child, nativeId)
    }

    fun reactChildCount(): Int = reactChildren.size

    fun reactChildAt(index: Int): View? = reactChildren.getOrNull(index)

    fun unmountReactChildAt(index: Int) {
        val child = reactChildren.getOrNull(index) ?: return
        reactChildren.removeAt(index)
        sheet.detachChild(child)
    }

    fun unmountAllReactChildren() {
        val all = ArrayList(reactChildren)
        reactChildren.clear()
        all.forEach { sheet.detachChild(it) }
    }

    /** Park a child here while the sheet is not presented (the real ViewGroup add). */
    internal fun park(child: View) {
        if (child.parent === this) return
        (child.parent as? ViewGroup)?.removeView(child)
        super.addView(child)
    }
}
