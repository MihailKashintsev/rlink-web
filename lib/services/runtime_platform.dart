import 'package:flutter/foundation.dart';

/// Unified runtime platform flags without direct `dart:io` dependency.
class RuntimePlatform {
  RuntimePlatform._();

  static bool get isWeb => kIsWeb;

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isDesktopWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static bool get isDesktopLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static bool get isDesktopMacos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isDesktop =>
      isDesktopWindows || isDesktopLinux || isDesktopMacos;
}
