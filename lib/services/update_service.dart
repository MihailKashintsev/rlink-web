import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const _kPat = String.fromEnvironment('GITHUB_PAT');
const _kOwner = String.fromEnvironment('GITHUB_OWNER');
const _kRepo = String.fromEnvironment('GITHUB_REPO');

/// Автообновление только для десктопа.
/// Android обновляется через RuStore автоматически.
bool get isUpdateSupported =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

class UpdateInfo {
  final String version;
  final String body;
  final String downloadUrl;
  final String assetName;
  const UpdateInfo(
      {required this.version,
      required this.body,
      required this.downloadUrl,
      required this.assetName});
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  final _dio = Dio(BaseOptions(
    baseUrl: 'https://api.github.com',
    headers: {
      'Authorization': 'Bearer $_kPat',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
  ));

  ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  Future<UpdateInfo?> checkForUpdate() async {
    if (!isUpdateSupported) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final response =
          await _dio.get('/repos/$_kOwner/$_kRepo/releases/latest');
      final data = response.data as Map<String, dynamic>;
      final latestVersion = data['tag_name'] as String;
      if (!_isNewer(latestVersion, 'v${info.version}')) return null;
      final asset = _findAssetForPlatform(data['assets'] as List<dynamic>);
      if (asset == null) return null;
      return UpdateInfo(
        version: latestVersion,
        body: data['body'] as String? ?? '',
        downloadUrl: asset['url'] as String,
        assetName: asset['name'] as String,
      );
    } on DioException catch (e) {
      debugPrint('[UpdateService] ${e.message}');
      return null;
    }
  }

  Future<void> downloadAndInstall(UpdateInfo info) async {
    if (!isUpdateSupported) return;
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/${info.assetName}';
    downloadProgress.value = 0.0;
    try {
      await _dio.download(
        info.downloadUrl,
        filePath,
        options: Options(headers: {'Accept': 'application/octet-stream'}),
        onReceiveProgress: (r, t) {
          if (t > 0) downloadProgress.value = r / t;
        },
      );
      downloadProgress.value = 1.0;
      if (Platform.isWindows) await _installWindows(filePath);
      if (Platform.isMacOS) await _installMacOS(filePath);
      if (Platform.isLinux) await _installLinux(filePath);
    } finally {
      downloadProgress.value = null;
    }
  }

  Future<void> _installWindows(String zipPath) async {
    final dir = await getTemporaryDirectory();
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final script =
        'Start-Sleep 2\nExpand-Archive -Force "$zipPath" "${dir.path}\\upd"\nCopy-Item "${dir.path}\\upd\\*" "$appDir" -Recurse -Force\nStart-Process "$exePath"';
    final f = File('${dir.path}\\update.ps1')..writeAsStringSync(script);
    await Process.start(
        'powershell', ['-ExecutionPolicy', 'Bypass', '-File', f.path],
        mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _installMacOS(String zipPath) async {
    final dir = await getTemporaryDirectory();
    final appBundle =
        File(Platform.resolvedExecutable).parent.parent.parent.path;
    await Process.run('unzip', ['-o', zipPath, '-d', dir.path]);
    final script =
        'sleep 2\ncp -R "${dir.path}/MeshChat.app/." "$appBundle/"\nopen "$appBundle"';
    final f = File('${dir.path}/update.sh')..writeAsStringSync(script);
    await Process.run('chmod', ['+x', f.path]);
    await Process.start('bash', [f.path], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _installLinux(String tarPath) async {
    final dir = await getTemporaryDirectory();
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final script =
        'sleep 2\nmkdir -p "${dir.path}/upd"\ntar -xzf "$tarPath" -C "${dir.path}/upd"\ncp -r "${dir.path}/upd/." "$appDir/"\n"$exePath" &';
    final f = File('${dir.path}/update.sh')..writeAsStringSync(script);
    await Process.run('chmod', ['+x', f.path]);
    await Process.start('bash', [f.path], mode: ProcessStartMode.detached);
    exit(0);
  }

  Map<String, dynamic>? _findAssetForPlatform(List<dynamic> assets) {
    final suffix = Platform.isWindows
        ? '_windows.zip'
        : Platform.isMacOS
            ? '_macos.zip'
            : '_linux.tar.gz';
    for (final a in assets) {
      if ((a['name'] as String).endsWith(suffix))
        return a as Map<String, dynamic>;
    }
    return null;
  }

  bool _isNewer(String latest, String current) {
    try {
      final l = _parse(latest);
      final c = _parse(current);
      for (int i = 0; i < 3; i++) {
        if (l[i] > c[i]) return true;
        if (l[i] < c[i]) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  List<int> _parse(String v) => v
      .replaceFirst('v', '')
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
}
