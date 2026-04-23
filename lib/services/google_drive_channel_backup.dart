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

  /// Web client ID нужен на Android/iOS/macOS, чтобы выдавался access token для Google APIs.
  static final GoogleSignIn _signIn = GoogleSignIn(
    scopes: _driveScopes,
    serverClientId: kIsWeb ? null : _webClientId,
    forceCodeForRefreshToken:
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
  );

  /// После выбора аккаунта без этого часто нет access token для Drive (особенно на новых GMS).
  static Future<bool> _ensureDriveScopes({required bool interactive}) async {
    if (_signIn.currentUser == null) return false;
    if (await _signIn.canAccessScopes(_driveScopes)) return true;
    if (!interactive) return false;
    if (!kIsWeb) await _waitForForegroundForInteractiveSignIn();
    return _signIn.requestScopes(_driveScopes);
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
      final granted = await _signIn.requestScopes(_driveScopes);
      if (granted) {
        client = await _signIn.authenticatedClient();
      }
    }
    return client;
  }

  /// Текущий аккаунт без диалога (если уже входили).
  static GoogleSignInAccount? get cachedCurrentUser => _signIn.currentUser;

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
    var a = await _signIn.signInSilently();
    if (a != null) return a;
    if (!interactive) return null;
    await _waitForForegroundForInteractiveSignIn();
    try {
      return await _signIn.signIn();
    } catch (e, st) {
      debugPrint('[RLINK][Drive] signIn failed: $e\n$st');
      return null;
    }
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
      final authClient = await _driveAuthClient(interactive: interactive);
      if (authClient == null) {
        return GoogleDriveSyncStatus(
          email: account.email,
          displayName: account.displayName,
        );
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
}
