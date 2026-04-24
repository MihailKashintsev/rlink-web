import 'package:flutter/foundation.dart';

/// Placeholder for browser storage bootstrap.
///
/// Existing services already persist via shared_preferences/secure storage on web.
/// Dedicated IndexedDB SQL backend will be wired incrementally behind adapters.
Future<void> initWebStorageIfNeeded() async {
  if (!kIsWeb) return;
}
