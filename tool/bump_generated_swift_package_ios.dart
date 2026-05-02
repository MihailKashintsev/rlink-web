// Syncs Flutter-generated SPM manifest with ios/Podfile `platform :ios`.
// `flutter pub get` always regenerates FlutterGeneratedPluginSwiftPackage with
// iOS 13, which breaks plugins that require a higher minimum (e.g. flutter_whisper_kit_apple → 16).
//
// Run from repo root after `flutter pub get` if you build from Xcode without `pod install`:
//   dart run tool/bump_generated_swift_package_ios.dart

import 'dart:io';

void main() {
  final root = Directory.current;
  final podfile = File.fromUri(root.uri.resolve('ios/Podfile'));
  final pkg = File.fromUri(root.uri.resolve(
    'ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift',
  ));

  if (!podfile.existsSync()) {
    stderr.writeln('bump_generated_swift_package_ios: ios/Podfile not found');
    exitCode = 1;
    return;
  }
  if (!pkg.existsSync()) {
    stdout.writeln(
      'bump_generated_swift_package_ios: no generated SPM package (run flutter pub get first)',
    );
    return;
  }

  final podText = podfile.readAsStringSync();
  final m = RegExp(r"platform\s+:ios,\s*'([^']+)'").firstMatch(podText) ??
      RegExp(r'platform\s+:ios,\s*"([^"]+)"').firstMatch(podText);
  if (m == null) {
    stderr.writeln('bump_generated_swift_package_ios: could not parse platform :ios in Podfile');
    exitCode = 1;
    return;
  }
  final ver = m.group(1)!;

  final body = pkg.readAsStringSync();
  final next = body.replaceAll(RegExp(r'\.iOS\("[0-9.]+"\)'), '.iOS("$ver")');
  if (next == body) {
    stdout.writeln(
      'bump_generated_swift_package_ios: Package.swift already matches or has no .iOS("…")',
    );
    return;
  }
  pkg.writeAsStringSync(next);
  stdout.writeln('bump_generated_swift_package_ios: set Flutter SPM package to .iOS("$ver")');
}
