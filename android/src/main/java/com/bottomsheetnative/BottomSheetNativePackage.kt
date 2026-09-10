package com.bottomsheetnative

import com.bottomsheetnative.bridge.NativeBottomSheetViewManager
import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.ModuleSpec
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * Registration surface for the native sheet. `BaseReactPackage` and the eager
 * `getViewManagers` override are both required under bridgeless.
 */
class BottomSheetNativePackage : BaseReactPackage() {

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? = null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider =
    ReactModuleInfoProvider { emptyMap() }

  override fun getViewManagers(reactContext: ReactApplicationContext): List<ModuleSpec> =
    listOf(
      ModuleSpec.viewManagerSpec { NativeBottomSheetViewManager(reactContext) },
    )
}
