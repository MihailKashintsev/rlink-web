import 'runtime_platform.dart';

/// Platform feature gates used by UI/services to avoid hardcoded checks.
class PlatformCapabilities {
  PlatformCapabilities._();
  static final PlatformCapabilities instance = PlatformCapabilities._();

  bool get supportsBleMesh => !RuntimePlatform.isWeb;
  bool get supportsWifiDirect => RuntimePlatform.isAndroid;
  bool get supportsNativeFilePaths => !RuntimePlatform.isWeb;
  bool get isWeb => RuntimePlatform.isWeb;
}
