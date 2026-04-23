import 'package:flutter/foundation.dart';

/// Глобальный сигнал: при записи голоса/квадратика или старте очереди аудио
/// все встроенные [VideoPlayer] должны поставиться на паузу.
class EmbeddedVideoPauseBus {
  EmbeddedVideoPauseBus._();
  static final EmbeddedVideoPauseBus instance = EmbeddedVideoPauseBus._();

  final ValueNotifier<int> generation = ValueNotifier(0);

  void bump() {
    generation.value++;
  }
}
