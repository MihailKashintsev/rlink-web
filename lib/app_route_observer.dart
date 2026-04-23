import 'package:flutter/material.dart';

/// Глобальный [RouteObserver] для экранов с [RouteAware] (обновление при возврате на маршрут).
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
