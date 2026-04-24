import 'relay_web_warmup_stub.dart'
    if (dart.library.html) 'relay_web_warmup_web.dart' as impl;

Future<void> warmupRelayWebSession(String baseUrl) => impl.warmupRelayWebSession(baseUrl);
