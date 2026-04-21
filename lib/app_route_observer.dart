import 'package:flutter/material.dart';

/// Для [RouteAware] (например, автообновление статусов разрешений при возврате в настройки).
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
