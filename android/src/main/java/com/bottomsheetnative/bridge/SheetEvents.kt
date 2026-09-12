package com.bottomsheetnative.bridge

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.events.Event

/** The sheet started presenting (emitted immediately, before the spring). */
class SheetPresentEvent(surfaceId: Int, viewTag: Int) :
    Event<SheetPresentEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = NAME
    override fun getEventData(): WritableMap = Arguments.createMap()

    companion object { const val NAME = "topPresent" }
}

/** The sheet is gone (emitted AFTER the slide-out, so JS can unmount then). */
class SheetDismissEvent(
    surfaceId: Int,
    viewTag: Int,
    private val reason: String,
) : Event<SheetDismissEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = NAME
    override fun getEventData(): WritableMap = Arguments.createMap().apply {
        putString("reason", reason)
    }

    companion object { const val NAME = "topDismiss" }
}

class SheetDragStartEvent(surfaceId: Int, viewTag: Int) :
    Event<SheetDragStartEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = NAME
    override fun getEventData(): WritableMap = Arguments.createMap()

    companion object { const val NAME = "topDragStart" }
}

class SheetDragEndEvent(surfaceId: Int, viewTag: Int) :
    Event<SheetDragEndEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = NAME
    override fun getEventData(): WritableMap = Arguments.createMap()

    companion object { const val NAME = "topDragEnd" }
}

/**
 * Settled geometry (dp). Emitted when the sheet settles on a detent, when the
 * footer's measured height changes and when the keyboard finishes moving —
 * never per frame.
 */
class SheetLayoutChangeEvent(
    surfaceId: Int,
    viewTag: Int,
    private val index: Int,
    private val sheetHeight: Float,
    private val bodyHeight: Float,
    private val maxBodyHeight: Float,
    private val footerHeight: Float,
    private val keyboardHeight: Float,
    private val hostHeight: Float,
    private val dynamic: Int,
    private val phase: Int,
) : Event<SheetLayoutChangeEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = NAME
    override fun getEventData(): WritableMap = Arguments.createMap().apply {
        putInt("index", index)
        putDouble("sheetHeight", sheetHeight.toDouble())
        putDouble("bodyHeight", bodyHeight.toDouble())
        putDouble("maxBodyHeight", maxBodyHeight.toDouble())
        putDouble("footerHeight", footerHeight.toDouble())
        putDouble("keyboardHeight", keyboardHeight.toDouble())
        putDouble("hostHeight", hostHeight.toDouble())
        putInt("dynamic", dynamic)
        putInt("phase", phase)
    }

    companion object { const val NAME = "topLayoutChange" }
}

/**
 * The sheet's live position (dp) — per frame while it moves, only while
 * `positionEventsEnabled`. Coalesced: only the latest frame matters.
 */
class SheetPositionChangeEvent(
    surfaceId: Int,
    viewTag: Int,
    private val position: Float,
    private val index: Float,
    private val height: Float,
) : Event<SheetPositionChangeEvent>(surfaceId, viewTag) {
    override fun getEventName(): String = NAME
    override fun canCoalesce(): Boolean = true
    override fun getEventData(): WritableMap = Arguments.createMap().apply {
        putDouble("position", position.toDouble())
        putDouble("index", index.toDouble())
        putDouble("height", height.toDouble())
    }

    companion object { const val NAME = "topPositionChange" }
}
