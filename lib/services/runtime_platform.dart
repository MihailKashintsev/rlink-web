import 'package:flutter/foundation.dart';

/// Unified runtime platform flags without direct `dart:io` dependency.
class RuntimePlatform {
  RuntimePlatform._();

  static bool get isWeb => kIsWeb;

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}
