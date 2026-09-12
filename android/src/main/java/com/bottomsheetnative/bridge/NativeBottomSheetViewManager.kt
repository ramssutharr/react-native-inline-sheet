package com.bottomsheetnative.bridge

import android.view.View
import com.bottomsheetnative.ui.NativeBottomSheetHostView
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.ViewGroupManager
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.NativeBottomSheetManagerDelegate
import com.facebook.react.viewmanagers.NativeBottomSheetManagerInterface

/**
 * Fabric bridge for the sheet: codegen'd interface + delegate, `@ReactProp`
 * kept alongside the overrides, events resolved lazily per emit.
 */
@ReactModule(name = NativeBottomSheetViewManager.NAME)
class NativeBottomSheetViewManager(
    private val reactContext: ReactApplicationContext,
) : ViewGroupManager<NativeBottomSheetHostView>(),
    NativeBottomSheetManagerInterface<NativeBottomSheetHostView> {

    private val delegate =
        NativeBottomSheetManagerDelegate<NativeBottomSheetHostView, NativeBottomSheetViewManager>(this)

    override fun getName(): String = NAME

    override fun getDelegate(): ViewManagerDelegate<NativeBottomSheetHostView> = delegate

    override fun createViewInstance(context: ThemedReactContext): NativeBottomSheetHostView =
        NativeBottomSheetHostView(context).also { attachEvents(it) }

    private fun attachEvents(view: NativeBottomSheetHostView) {
        fun dispatcher() = UIManagerHelper.getEventDispatcherForReactTag(reactContext, view.id)
        fun surfaceId() = UIManagerHelper.getSurfaceId(view)

        view.onPresent = {
            dispatcher()?.dispatchEvent(SheetPresentEvent(surfaceId(), view.id))
        }
        view.onDismiss = { reason ->
            dispatcher()?.dispatchEvent(SheetDismissEvent(surfaceId(), view.id, reason))
        }
        view.onDragStart = {
            dispatcher()?.dispatchEvent(SheetDragStartEvent(surfaceId(), view.id))
        }
        view.onDragEnd = {
            dispatcher()?.dispatchEvent(SheetDragEndEvent(surfaceId(), view.id))
        }
        view.onLayoutChange = { index, sheetHeight, bodyHeight, maxBodyHeight, footerHeight, keyboardHeight,
                                hostHeight, dynamic, phase ->
            dispatcher()?.dispatchEvent(
                SheetLayoutChangeEvent(
                    surfaceId(), view.id, index, sheetHeight, bodyHeight, maxBodyHeight,
                    footerHeight, keyboardHeight, hostHeight, dynamic, phase,
                ),
            )
        }
        view.onPositionChange = { position, index, height ->
            dispatcher()?.dispatchEvent(SheetPositionChangeEvent(surfaceId(), view.id, position, index, height))
        }
    }

    // Commands arrive by name; the codegen delegate parses the args and calls
    // the typed methods below.
    override fun receiveCommand(root: NativeBottomSheetHostView, commandId: String, args: ReadableArray?) {
        delegate.receiveCommand(root, commandId, args)
    }

    override fun present(view: NativeBottomSheetHostView, index: Int, animated: Boolean) {
        view.present(index, animated)
    }

    override fun dismiss(view: NativeBottomSheetHostView) {
        view.dismiss()
    }

    override fun snapTo(view: NativeBottomSheetHostView, index: Int) {
        view.snapTo(index)
    }

    override fun snapToHeight(view: NativeBottomSheetHostView, spec: String?) {
        view.snapToHeight(spec ?: "")
    }

    /**
     * Runs once per commit, after every prop for that commit has been
     * applied — detents are re-resolved here, so prop order never matters.
     */
    override fun onAfterUpdateTransaction(view: NativeBottomSheetHostView) {
        super.onAfterUpdateTransaction(view)
        view.onPropsApplied()
    }

    override fun onDropViewInstance(view: NativeBottomSheetHostView) {
        view.onDropped()
        super.onDropViewInstance(view)
    }

    override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> =
        mutableMapOf(
            SheetPresentEvent.NAME to mapOf("registrationName" to "onPresent"),
            SheetDismissEvent.NAME to mapOf("registrationName" to "onDismiss"),
            SheetDragStartEvent.NAME to mapOf("registrationName" to "onDragStart"),
            SheetDragEndEvent.NAME to mapOf("registrationName" to "onDragEnd"),
            SheetLayoutChangeEvent.NAME to mapOf("registrationName" to "onLayoutChange"),
            SheetPositionChangeEvent.NAME to mapOf("registrationName" to "onPositionChange"),
        )

    // MARK: - Props

    @ReactProp(name = "detents")
    override fun setDetents(view: NativeBottomSheetHostView, value: String?) {
        view.setDetentsSpec(value ?: "auto")
    }

    @ReactProp(name = "initialDetent")
    override fun setInitialDetent(view: NativeBottomSheetHostView, value: Int) {
        view.setInitialDetent(value)
    }

    @ReactProp(name = "maxDetentInset")
    override fun setMaxDetentInset(view: NativeBottomSheetHostView, value: Float) {
        view.setMaxDetentInsetDp(value)
    }

    @ReactProp(name = "bottomInset")
    override fun setBottomInset(view: NativeBottomSheetHostView, value: Float) {
        view.setBottomInsetDp(value)
    }

    @ReactProp(name = "maxAutoHeight")
    override fun setMaxAutoHeight(view: NativeBottomSheetHostView, value: Float) {
        view.setMaxAutoHeightDp(value)
    }

    @ReactProp(name = "contentBottomInset")
    override fun setContentBottomInset(view: NativeBottomSheetHostView, value: Float) {
        view.setContentBottomInsetDp(value)
    }

    @ReactProp(name = "enableContentPanningGesture")
    override fun setEnableContentPanningGesture(view: NativeBottomSheetHostView, value: Boolean) {
        view.setEnableContentPanningGesture(value)
    }

    @ReactProp(name = "enableHandlePanningGesture")
    override fun setEnableHandlePanningGesture(view: NativeBottomSheetHostView, value: Boolean) {
        view.setEnableHandlePanningGesture(value)
    }

    @ReactProp(name = "enableOverDrag")
    override fun setEnableOverDrag(view: NativeBottomSheetHostView, value: Boolean) {
        view.setEnableOverDrag(value)
    }

    @ReactProp(name = "overDragResistanceFactor")
    override fun setOverDragResistanceFactor(view: NativeBottomSheetHostView, value: Float) {
        view.setOverDragResistanceFactor(value)
    }

    @ReactProp(name = "restoreDetentOnKeyboardHide")
    override fun setRestoreDetentOnKeyboardHide(view: NativeBottomSheetHostView, value: Boolean) {
        view.setRestoreDetentOnKeyboardHide(value)
    }

    @ReactProp(name = "detached")
    override fun setDetached(view: NativeBottomSheetHostView, value: Boolean) {
        view.setDetached(value)
    }

    @ReactProp(name = "detachedMargin")
    override fun setDetachedMargin(view: NativeBottomSheetHostView, value: Float) {
        view.setDetachedMarginDp(value)
    }

    @ReactProp(name = "positionEventsEnabled")
    override fun setPositionEventsEnabled(view: NativeBottomSheetHostView, value: Boolean) {
        view.setPositionEventsEnabled(value)
    }

    @ReactProp(name = "dimColor", customType = "Color")
    override fun setDimColor(view: NativeBottomSheetHostView, value: Int?) {
        view.setDimColor(value)
    }

    @ReactProp(name = "grabberWidth")
    override fun setGrabberWidth(view: NativeBottomSheetHostView, value: Float) {
        view.setGrabberWidthDp(value)
    }

    @ReactProp(name = "grabberHeight")
    override fun setGrabberHeight(view: NativeBottomSheetHostView, value: Float) {
        view.setGrabberHeightDp(value)
    }

    @ReactProp(name = "dimmed")
    override fun setDimmed(view: NativeBottomSheetHostView, value: Boolean) {
        view.setDimmed(value)
    }

    @ReactProp(name = "dimOpacity")
    override fun setDimOpacity(view: NativeBottomSheetHostView, value: Float) {
        view.setDimOpacity(value)
    }

    @ReactProp(name = "cornerRadius")
    override fun setCornerRadius(view: NativeBottomSheetHostView, value: Float) {
        view.setCornerRadiusDp(value)
    }

    @ReactProp(name = "grabber")
    override fun setGrabber(view: NativeBottomSheetHostView, value: Boolean) {
        view.setGrabber(value)
    }

    @ReactProp(name = "grabberAreaHeight")
    override fun setGrabberAreaHeight(view: NativeBottomSheetHostView, value: Float) {
        view.setGrabberAreaHeightDp(value)
    }

    @ReactProp(name = "sheetBackgroundColor", customType = "Color")
    override fun setSheetBackgroundColor(view: NativeBottomSheetHostView, value: Int?) {
        view.setSheetBackgroundColor(value)
    }

    @ReactProp(name = "grabberColor", customType = "Color")
    override fun setGrabberColor(view: NativeBottomSheetHostView, value: Int?) {
        view.setGrabberColor(value)
    }

    @ReactProp(name = "enablePanToDismiss")
    override fun setEnablePanToDismiss(view: NativeBottomSheetHostView, value: Boolean) {
        view.setEnablePanToDismiss(value)
    }

    @ReactProp(name = "dismissOnBackdropPress")
    override fun setDismissOnBackdropPress(view: NativeBottomSheetHostView, value: Boolean) {
        view.setDismissOnBackdropPress(value)
    }

    @ReactProp(name = "keyboardMode")
    override fun setKeyboardMode(view: NativeBottomSheetHostView, value: String?) {
        view.setKeyboardMode(value ?: "lift-sheet")
    }

    @ReactProp(name = "expandOnKeyboard")
    override fun setExpandOnKeyboard(view: NativeBottomSheetHostView, value: Boolean) {
        view.setExpandOnKeyboard(value)
    }

    @ReactProp(name = "dismissKeyboardOnDrag")
    override fun setDismissKeyboardOnDrag(view: NativeBottomSheetHostView, value: Boolean) {
        view.setDismissKeyboardOnDrag(value)
    }

    @ReactProp(name = "hostStrategy")
    override fun setHostStrategy(view: NativeBottomSheetHostView, value: String?) {
        view.setHostStrategy(value ?: "outermost-screen")
    }

    // ── RN child mounting ──
    // Every RN child is re-parented into a native slot (body or footer) keyed
    // by its nativeID. These MUST describe only what RN mounted, wherever the
    // view currently lives: `SurfaceMountingManager.removeViewAt` asks
    // `getChildAt` first and, on a mismatch, scans the parent's real children
    // — and if it does not find the view there it logs "already removed" and
    // silently skips the unmount.

    override fun addView(parent: NativeBottomSheetHostView, child: View, index: Int) {
        parent.mountReactChild(child, index)
    }

    override fun getChildCount(parent: NativeBottomSheetHostView): Int = parent.reactChildCount()

    override fun getChildAt(parent: NativeBottomSheetHostView, index: Int): View? =
        parent.reactChildAt(index)

    override fun removeViewAt(parent: NativeBottomSheetHostView, index: Int) {
        parent.unmountReactChildAt(index)
    }

    override fun removeAllViews(parent: NativeBottomSheetHostView) {
        parent.unmountAllReactChildren()
    }

    override fun needsCustomLayoutForChildren(): Boolean = false

    companion object {
        const val NAME = "NativeBottomSheet"
    }
}
