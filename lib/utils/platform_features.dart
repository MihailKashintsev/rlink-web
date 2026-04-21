import 'dart:io' show Platform;

/// «Жидкое стекло» и нативные крутилки — только для iOS 26+ (по версии ОС).
bool get iosLiquidGlassAndNativePickers {
  if (!Platform.isIOS) return false;
  final raw = Platform.operatingSystemVersion;
  final m = RegExp(r'Version (\d+)', caseSensitive: false).firstMatch(raw);
  final major = int.tryParse(m?.group(1) ?? '') ?? 0;
  return major >= 26;
}
