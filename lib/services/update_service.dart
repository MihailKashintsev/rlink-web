import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

const _kGithubPat = String.fromEnvironment('GITHUB_PAT', defaultValue: '');
const _kGithubOwner = String.fromEnvironment('GITHUB_OWNER', defaultValue: '');
const _kGithubRepo = String.fromEnvironment('GITHUB_REPO', defaultValue: '');

/// Публичные релизы (теги вида v0.0.5): https://github.com/MihailKashintsev/Rlink-releases/releases
const _kDefaultReleaseOwner = 'MihailKashintsev';
const _kDefaultReleaseRepo = 'Rlink-releases';

/// Страница загрузки APK / инструкций (после обнаружения более новой версии на GitHub).
const _kMobileDownloadPageUrl = 'https://rendergames.online/rlink';

/// Уведомление UI о доступном обновлении (после фоновой проверки GitHub).
final ValueNotifier<UpdateInfo?> pendingUpdateNotifier =
    ValueNotifier<UpdateInfo?>(null);

Map<String, String> _githubApiHeaders() {
  final h = <String, String>{
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  if (_kGithubPat.isNotEmpty) {
    h['Authorization'] = 'Bearer $_kGithubPat';
  }
  return h;
}

/// Обновление: десктоп (ассеты с GitHub), мобильные — страница загрузки.
bool get isUpdateSupported =>
    !kIsWeb &&
    (Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isAndroid ||
        Platform.isIOS);

class UpdateInfo {
  final String version;
  final String body;
  final String downloadUrl;
  final String assetName;
  /// true = открыть [downloadUrl] в браузере (страница установки); false = скачать ассет с GitHub (десктоп).
  final bool openExternalDownloadPage;

  const UpdateInfo({
    required this.version,
    required this.body,
    required this.downloadUrl,
    required this.assetName,
    this.openExternalDownloadPage = false,
  });
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  final _dio = Dio(BaseOptions(
    baseUrl: 'https://api.github.com',
    headers: _githubApiHeaders(),
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
  ));

  ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  String get _owner =>
      _kGithubOwner.isNotEmpty ? _kGithubOwner : _kDefaultReleaseOwner;
  String get _repo =>
      _kGithubRepo.isNotEmpty ? _kGithubRepo : _kDefaultReleaseRepo;

  Future<UpdateInfo?> checkForUpdate() async {
    if (!isUpdateSupported) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final current = _normalizeVersionTag(info.version);

      final response = await _dio.get(
        '/repos/$_owner/$_repo/releases',
        queryParameters: const {'per_page': '40'},
      );
      final list = response.data as List<dynamic>;
      Map<String, dynamic>? bestRelease;
      String? bestTag;

      for (final raw in list) {
        final m = raw as Map<String, dynamic>;
        if (m['draft'] == true) continue;
        if (m['prerelease'] == true) continue;
        final tag = m['tag_name'] as String?;
        if (tag == null) continue;
        final norm = _normalizeVersionTag(tag);
        if (!_isNewer(norm, current)) continue;
        if (bestTag == null || _isNewer(norm, bestTag)) {
          bestTag = norm;
          bestRelease = m;
        }
      }
      if (bestRelease == null || bestTag == null) return null;

      final displayTag = bestRelease['tag_name'] as String? ?? bestTag;

      if (Platform.isAndroid || Platform.isIOS) {
        return UpdateInfo(
          version: displayTag,
          body: bestRelease['body'] as String? ?? '',
          downloadUrl: _kMobileDownloadPageUrl,
          assetName: 'web',
          openExternalDownloadPage: true,
        );
      }

      final assets = bestRelease['assets'] as List<dynamic>?;
      if (assets == null) return null;
      final asset = _findAssetForPlatform(assets);
      if (asset == null) return null;
      return UpdateInfo(
        version: displayTag,
        body: bestRelease['body'] as String? ?? '',
        downloadUrl: asset['url'] as String,
        assetName: asset['name'] as String,
      );
    } on DioException catch (e) {
      debugPrint('[UpdateService] ${e.message}');
      return null;
    }
  }

  /// Открывает страницу загрузки в браузере (мобильные) или скачивает архив (десктоп).
  Future<void> downloadAndInstall(UpdateInfo info) async {
    if (!isUpdateSupported) return;

    if (info.openExternalDownloadPage) {
      final uri = Uri.parse(info.downloadUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }

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
      if ((a['name'] as String).endsWith(suffix)) {
        return a as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// Приводит `v0.1.2` / `0.1.2` к виду `v0.1.2` для сравнения.
  String _normalizeVersionTag(String v) {
    final t = v.trim();
    if (t.isEmpty) return 'v0.0.0';
    final core = t.split('-').first;
    if (core.toLowerCase().startsWith('v')) return core;
    return 'v$core';
  }

  bool _isNewer(String latest, String current) {
    try {
      final l = _parse(latest);
      final c = _parse(current);
      final n = l.length > c.length ? l.length : c.length;
      for (int i = 0; i < n; i++) {
        final li = i < l.length ? l[i] : 0;
        final ci = i < c.length ? c[i] : 0;
        if (li > ci) return true;
        if (li < ci) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  List<int> _parse(String v) => v
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
}
