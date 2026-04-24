import 'web_state_store_stub.dart'
    if (dart.library.html) 'web_state_store_web.dart' as impl;

String? readWebState(String key) => impl.readWebState(key);
Future<void> writeWebState(String key, String value) => impl.writeWebState(key, value);
