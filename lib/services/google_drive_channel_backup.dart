import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, debugPrint;
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as gapis;
import 'package:googleapis/drive/v3.dart' as drive;

/// Состояние аккаунта Google Drive для экрана настроек (квота из [about.get]).
class GoogleDriveSyncStatus {
  final String? email;
  final String? displayName;

  /// Лимит хранилища, байт (null если API не вернул).
  final int? limitBytes;

  /// Занято всего (включая Диск, Почту, Фото), байт.
  final int? usageBytes;

  const GoogleDriveSyncStatus({
    this.email,
    this.displayName,
    this.limitBytes,
    this.usageBytes,
  });

  int? get freeBytes {
    if (limitBytes == null || usageBytes == null) return null;
    if (limitBytes! <= 0) return null;
    final f = limitBytes! - usageBytes!;
    return f < 0 ? 0 : f;
  }
}

/// Загрузка зашифрованного снимка канала в Google Drive (OAuth в Google Cloud Console).
class GoogleDriveChannelBackup {
  GoogleDriveChannelBackup._();

  /// OAuth-клиент типа «Веб-приложение» — для Android нужен как [GoogleSignIn.serverClientId]
  /// при запросе токена для Google APIs.
  static const String _webClientId =
      '180782636430-cr0ogo622n3ng26aeu00j0pkn4286dvs.apps.googleusercontent.com';

  static final List<String> _driveScopes = [drive.DriveApi.driveFileScope];
  static String? _lastSignInError;
  static String? get lastSignInError => _lastSignInError;

  /// Web client ID нужен на Android/iOS/macOS, чтобы выдавался access token для Google APIs.
  static final GoogleSignIn _signIn = GoogleSignIn(
    scopes: _driveScopes,
    serverClientId: kIsWeb ? null : _webClientId,
    forceCodeForRefreshToken:
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
  );

  static bool _isScopesApiUnsupported(Object error) {
    if (error is UnimplementedError) return true;
    final msg = error.toString();
    return msg.contains('canAccessScopes() has not been implemented') ||
        msg.contains('requestScopes() has not been implemented');
  }

  /// После выбора аккаунта без этого часто нет access token для Drive (особенно на новых GMS).
  static Future<bool> _ensureDriveScopes({required bool interactive}) async {
    if (_signIn.currentUser == null) return false;
    try {
      if (await _signIn.canAccessScopes(_driveScopes)) return true;
    } catch (e, st) {
      if (_isScopesApiUnsupported(e)) {
        debugPrint(
            '[RLINK][Drive] canAccessScopes unsupported → fallback path');
        return true;
      }
      debugPrint('[RLINK][Drive] canAccessScopes failed: $e\n$st');
    }
    if (!interactive) return false;
    if (!kIsWeb) await _waitForForegroundForInteractiveSignIn();
    try {
      return await _signIn.requestScopes(_driveScopes);
    } catch (e, st) {
      if (_isScopesApiUnsupported(e)) {
        debugPrint('[RLINK][Drive] requestScopes unsupported → fallback path');
        return true;
      }
      debugPrint('[RLINK][Drive] requestScopes failed: $e\n$st');
      return false;
    }
  }

  static Future<gapis.AuthClient?> _driveAuthClient({
    required bool interactive,
  }) async {
    if (!await _ensureDriveScopes(interactive: interactive)) {
      return null;
    }
    var client = await _signIn.authenticatedClient();
    if (client != null) return client;
    if (interactive && _signIn.currentUser != null) {
      if (!kIsWeb) await _waitForForegroundForInteractiveSignIn();
      var granted = false;
      try {
        granted = await _signIn.requestScopes(_driveScopes);
      } catch (e, st) {
        if (_isScopesApiUnsupported(e)) {
          debugPrint('[RLINK][Drive] requestScopes unsupported in retry path');
          granted = true;
        } else {
          debugPrint('[RLINK][Drive] requestScopes retry failed: $e\n$st');
        }
      }
      if (granted) {
        client = await _signIn.authenticatedClient();
      }
    }
    return client;
  }

  /// Текущий аккаунт без диалога (если уже входили).
  static GoogleSignInAccount? get cachedCurrentUser => _signIn.currentUser;

  /// Локально отвязывает Google-аккаунт (sign-out + revoke where supported).
  static Future<bool> disconnectCurrentUser() async {
    try {
      await _signIn.disconnect();
      debugPrint('[RLINK][Drive] disconnect() done');
    } catch (e, st) {
      debugPrint('[RLINK][Drive] disconnect() failed: $e\n$st');
    }
    try {
      await _signIn.signOut();
      debugPrint('[RLINK][Drive] signOut() done');
    } catch (e, st) {
      debugPrint('[RLINK][Drive] signOut() failed: $e\n$st');
    }
    return _signIn.currentUser == null;
  }

  /// На Android интерактивный [GoogleSignIn.signIn] требует foreground Activity;
  /// при предварительном запуске Dart из [RlinkApplication] плагин может ещё не
  /// получить activity — ждём resumed и даём кадр на attach.
  static Future<void> _waitForForegroundForInteractiveSignIn() async {
    if (kIsWeb) return;
    final binding = WidgetsBinding.instance;
    if (binding.lifecycleState != AppLifecycleState.resumed) {
      for (var i = 0; i < 80; i++) {
        if (binding.lifecycleState == AppLifecycleState.resumed) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    // Кадр на attach Activity к плагину после resumed.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  /// Пытается восстановить сессию; при [interactive] открывает выбор аккаунта.
  static Future<GoogleSignInAccount?> ensureUserSignedIn({
    bool interactive = true,
  }) async {
    _lastSignInError = null;
    // Quick path: в памяти singleton'а уже держится currentUser — после удачного
    // interactive-входа это самый надёжный источник (на iOS signInSilently
    // иногда возвращает null пока GIDSignIn не доделает restore из keychain).
    final cached = _signIn.currentUser;
    if (cached != null) {
      debugPrint('[RLINK][Drive] currentUser (cached) → ${cached.email}');
      return cached;
    }
    try {
      final silent = await _signIn.signInSilently();
      if (silent != null) {
        debugPrint('[RLINK][Drive] signInSilently → ${silent.email}');
        return silent;
      }
      debugPrint('[RLINK][Drive] signInSilently → null (no saved session)');
    } catch (e, st) {
      debugPrint('[RLINK][Drive] signInSilently threw: $e\n$st');
    }
    // Ещё раз проверим currentUser: signInSilently сам публикует его через стрим,
    // но Future возвращается раньше, чем успевает прогнаться _setCurrentUser.
    final postSilent = _signIn.currentUser;
    if (postSilent != null) {
      debugPrint(
          '[RLINK][Drive] currentUser (post-silent) → ${postSilent.email}');
      return postSilent;
    }
    if (!interactive) return null;
    for (var attempt = 0; attempt < 2; attempt++) {
      await _waitForForegroundForInteractiveSignIn();
      try {
        debugPrint('[RLINK][Drive] signIn() invoked '
            '(attempt=${attempt + 1}, platform=$defaultTargetPlatform, lifecycle=${WidgetsBinding.instance.lifecycleState})');
        final a = await _signIn.signIn();
        debugPrint(
            '[RLINK][Drive] signIn() → ${a?.email ?? 'null (user canceled or silent fail)'}');
        final resolved = a ?? _signIn.currentUser;
        if (resolved != null) return resolved;
      } catch (e, st) {
        _lastSignInError = e.toString();
        debugPrint('[RLINK][Drive] signIn failed: $e\n$st');
      }
      await Future<void>.delayed(const Duration(milliseconds: 220));
    }
    return _signIn.currentUser;
  }

  /// Аккаунт и квота для UI настроек. При [interactive]==false только тихий вход.
  static Future<GoogleDriveSyncStatus?> getSyncStatus({
    bool interactive = false,
  }) async {
    try {
      final account = await ensureUserSignedIn(interactive: interactive);
      if (account == null) {
        return const GoogleDriveSyncStatus();
      }
      late final GoogleDriveSyncStatus accountOnlyStatus;
      accountOnlyStatus = GoogleDriveSyncStatus(
        email: account.email,
        displayName: account.displayName,
      );

      gapis.AuthClient? authClient;
      try {
        authClient = await _driveAuthClient(interactive: interactive);
      } catch (e, st) {
        debugPrint('[RLINK][Drive] getSyncStatus auth client failed: $e\n$st');
        return accountOnlyStatus;
      }
      if (authClient == null) {
        return accountOnlyStatus;
      }
      try {
        final api = drive.DriveApi(authClient);
        final about = await api.about.get(
          $fields: 'user,storageQuota',
        );
        int? parseQuota(String? s) {
          if (s == null || s.isEmpty) return null;
          return int.tryParse(s);
        }

        final q = about.storageQuota;
        return GoogleDriveSyncStatus(
          email: about.user?.emailAddress ?? account.email,
          displayName: about.user?.displayName ?? account.displayName,
          limitBytes: parseQuota(q?.limit),
          usageBytes: parseQuota(q?.usage),
        );
      } catch (e, st) {
        debugPrint('[RLINK][Drive] getSyncStatus about.get failed: $e\n$st');
        return accountOnlyStatus;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] getSyncStatus: $e\n$st');
      return null;
    }
  }

  /// Один файл на канал: при наличии [existingFileId] содержимое перезаписывается.
  static Future<String?> uploadOrUpdateEncryptedFile({
    required String fileName,
    required Uint8List ciphertext,
    String? existingFileId,
  }) async {
    try {
      final account = await ensureUserSignedIn(interactive: true);
      if (account == null) return null;
      final authClient = await _driveAuthClient(interactive: true);
      if (authClient == null) return null;
      try {
        final api = drive.DriveApi(authClient);
        final media = drive.Media(
          Stream<List<int>>.value(ciphertext),
          ciphertext.length,
        );

        if (existingFileId != null && existingFileId.isNotEmpty) {
          try {
            await api.files.update(
              drive.File()..name = fileName,
              existingFileId,
              uploadMedia: media,
            );
            return existingFileId;
          } catch (e) {
            debugPrint('[RLINK][Drive] update failed, creating new: $e');
          }
        }

        final created = await api.files.create(
          drive.File()..name = fileName,
          uploadMedia: media,
        );
        return created.id;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] upload failed: $e\n$st');
      return null;
    }
  }

  /// Делает файл доступным по ссылке (Anyone with link → viewer) и возвращает прямую ссылку для скачивания.
  /// Вызывается сразу после [uploadOrUpdateEncryptedFile] чтобы подписчики могли скачать снимок без авторизации.
  static Future<String?> makePublicAndGetDownloadUrl(String fileId) async {
    try {
      final authClient = await _driveAuthClient(interactive: true);
      if (authClient == null) return null;
      try {
        final api = drive.DriveApi(authClient);
        await api.permissions.create(
          drive.Permission()
            ..type = 'anyone'
            ..role = 'reader',
          fileId,
        );
        final file = await api.files.get(
          fileId,
          $fields: 'webContentLink',
        ) as drive.File;
        final url = file.webContentLink;
        debugPrint('[RLINK][Drive] makePublic ok: $fileId → $url');
        return url;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] makePublic failed: $e\n$st');
      return null;
    }
  }

  /// Удаляет файл-резерв канала на Google Drive.
  /// Возвращает true, если файл удалён или уже отсутствует.
  static Future<bool> deleteBackupFile({
    required String fileId,
    bool interactive = true,
  }) async {
    if (fileId.trim().isEmpty) return true;
    try {
      final account = await ensureUserSignedIn(interactive: interactive);
      if (account == null) return false;
      final authClient = await _driveAuthClient(interactive: interactive);
      if (authClient == null) return false;
      try {
        final api = drive.DriveApi(authClient);
        await api.files.delete(fileId);
        debugPrint('[RLINK][Drive] delete file ok: $fileId');
        return true;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      // На некоторых аккаунтах API может вернуть 404 на уже удалённый id.
      final msg = e.toString().toLowerCase();
      if (msg.contains('404') ||
          msg.contains('not found') ||
          msg.contains('file not found')) {
        debugPrint('[RLINK][Drive] delete file treated as already removed: $e');
        return true;
      }
      debugPrint('[RLINK][Drive] delete file failed: $e\n$st');
      return false;
    }
  }
}
