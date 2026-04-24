import '../services/runtime_platform.dart';

/// «Жидкое стекло» и нативные крутилки — только для iOS 26+ (по версии ОС).
bool get iosLiquidGlassAndNativePickers {
  // Web/desktop-safe fallback: disable iOS-only visual mode outside iOS.
  return RuntimePlatform.isIos;
}
