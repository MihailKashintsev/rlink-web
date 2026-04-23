/// Версия для отображения в UI. При релизе обновляй вместе с [pubspec.yaml] `version: X.Y.Z+N`.
class AppVersion {
  AppVersion._();

  static const String version = '0.0.6';
  static const String buildNumber = '8';

  static String get label => '$version ($buildNumber)';
}
