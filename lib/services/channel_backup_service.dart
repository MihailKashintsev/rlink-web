import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import 'ble_service.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'google_drive_channel_backup.dart';
import 'gossip_router.dart';
import 'image_service.dart';
import 'relay_service.dart';

/// Резерв истории канала: отдельный симметричный ключ на канал, шифрование снимка,
/// тихая доставка чанков подписчикам и опциональная копия на Google Drive у админа.
class ChannelBackupService {
  ChannelBackupService._();
  static final ChannelBackupService instance = ChannelBackupService._();

  static bool get _isMobile => Platform.isIOS || Platform.isAndroid;

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final Map<String, _BakAssembly> _assemblies = {};
  final Map<String, _PendingDecrypt> _pendingDecryptByChannel = {};

  String _symStorageKey(String channelId) => 'chbak_sym_$channelId';

  Future<void> _writeSymKeyBytes(String channelId, Uint8List key32) async {
    final v = base64Encode(key32);
    if (_isMobile) {
      await _secure.write(key: _symStorageKey(channelId), value: v);
    } else {
      final p = await SharedPreferences.getInstance();
      await p.setString(_symStorageKey(channelId), v);
    }
  }

  Future<Uint8List?> _readSymKeyBytes(String channelId) async {
    final String? raw =
        _isMobile ? await _secure.read(key: _symStorageKey(channelId)) : null;
    final s = _isMobile
        ? raw
        : (await SharedPreferences.getInstance())
            .getString(_symStorageKey(channelId));
    if (s == null || s.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  /// Ключ снимка для канала (создаётся при первом резерве админом или при приёме wrap).
  Future<Uint8List> getOrCreateSymmetricKey(String channelId) async {
    final existing = await _readSymKeyBytes(channelId);
    if (existing != null && existing.length == 32) return existing;
    final rng = Random.secure();
    final key = Uint8List.fromList(
        List<int>.generate(32, (_) => rng.nextInt(256)));
    await _writeSymKeyBytes(channelId, key);
    return key;
  }

  Future<int> _appliedRev(String channelId) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('chbak_applied_$channelId') ?? 0;
  }

  Future<void> _setAppliedRev(String channelId, int rev) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('chbak_applied_$channelId', rev);
  }

  Future<String?> _readKeysFileId(String channelId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('chbak_kfid_$channelId');
  }

  Future<void> _writeKeysFileId(String channelId, String fileId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('chbak_kfid_$channelId', fileId);
  }

  static String backupMsgId(String channelId, int rev) =>
      'chbak_${ChannelService.compactChannelId(channelId)}_$rev';

  List<String> _splitChunks(Uint8List data) {
    final chunks = <String>[];
    var offset = 0;
    while (offset < data.length) {
      final end = (offset + kImgChunkBytes).clamp(0, data.length);
      chunks.add(base64Encode(data.sublist(offset, end)));
      offset = end;
    }
    return chunks;
  }

  Future<String?> _x25519For(String userId) async {
    final c = await ChatStorageService.instance.getContact(userId);
    final fromContact = c?.x25519Key;
    if (fromContact != null && fromContact.isNotEmpty) return fromContact;
    var k = BleService.instance.getPeerX25519Key(userId);
    if (k != null && k.isNotEmpty) return k;
    k = RelayService.instance.getPeerX25519Key(userId);
    if (k != null && k.isNotEmpty) return k;
    return null;
  }

  /// После удаления поста/комментария и т.п.: обновить Google Drive и P2P-снимок,
  /// если текущий пользователь — админ и включён резерв на Drive (как после нового поста).
  Future<void> publishBackupIfAdminDriveEnabled(String channelId) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    final ch = await ChannelService.instance.getChannel(channelId);
    if (ch == null || ch.adminId != myId || !ch.driveBackupEnabled) return;
    await publishBackup(ch);
  }

  /// Публикация снимка (только админ канала).
  Future<void> publishBackup(Channel channel) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (channel.adminId != myId) return;

    final rev = channel.driveBackupRev + 1;
    final snap = await ChannelService.instance.buildChannelBackupSnapshot(channel.id);
    snap['rev'] = rev;
    final jsonStr = jsonEncode(snap);
    final key = await getOrCreateSymmetricKey(channel.id);
    final sealed =
        await CryptoService.instance.sealSymmetric(utf8.encode(jsonStr), key);

    // Wrap symmetric key per subscriber for gossip delivery and keys-file on Drive.
    final subs = channel.subscriberIds.toSet()..remove(myId);
    final wrappedKeys = <String, dynamic>{};
    for (final uid in subs) {
      final x = await _x25519For(uid);
      if (x == null) continue;
      final em = await CryptoService.instance.encryptMessage(
        plaintext: base64.encode(key),
        recipientX25519KeyBase64: x,
      );
      await GossipRouter.instance.sendChannelBackupKey(
        channelId: channel.id,
        recipientPublicKeyHex: uid,
        wrapped: em,
      );
      wrappedKeys[uid] = em.toJson();
    }

    await Future.delayed(const Duration(milliseconds: 400));
    final mid = backupMsgId(channel.id, rev);
    final chunks = _splitChunks(sealed);
    await GossipRouter.instance.sendChannelBackupMeta(
      channelId: channel.id,
      rev: rev,
      totalChunks: chunks.length,
      adminId: myId,
      msgId: mid,
    );
    for (var i = 0; i < chunks.length; i++) {
      await GossipRouter.instance.sendChannelBackupChunk(
        msgId: mid,
        index: i,
        base64Data: chunks[i],
      );
      if (i % 6 == 5) {
        await Future.delayed(const Duration(milliseconds: 12));
      }
    }

    String? fileId;
    String? fileUrl;
    String? keysFileId;
    String? keysFileUrl;
    if (channel.driveBackupEnabled) {
      final compact = ChannelService.compactChannelId(channel.id);
      // Upload encrypted snapshot.
      fileId = await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
        fileName: 'Rlink_ch_$compact.bin',
        ciphertext: sealed,
        existingFileId: channel.driveFileId,
      );
      if (fileId != null) {
        fileUrl = await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(fileId);
      }

      // Upload per-subscriber wrapped keys as a public JSON file.
      // Each value is an EncryptedMessage.toJson() — individually E2E encrypted.
      if (wrappedKeys.isNotEmpty) {
        final keysJson = jsonEncode({
          'v': 1,
          'channelId': channel.id,
          'rev': rev,
          'keys': wrappedKeys,
        });
        final keysBytes = Uint8List.fromList(utf8.encode(keysJson));
        final existingKeysFileId = await _readKeysFileId(channel.id);
        keysFileId = await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
          fileName: 'Rlink_ch_${compact}_keys.json',
          ciphertext: keysBytes,
          existingFileId: existingKeysFileId,
        );
        if (keysFileId != null) {
          await _writeKeysFileId(channel.id, keysFileId);
          keysFileUrl =
              await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(keysFileId);
        }
      }
    }

    final next = channel.copyWith(
      driveBackupRev: rev,
      driveFileId: fileId ?? channel.driveFileId,
      driveFileUrl: fileUrl ?? channel.driveFileUrl,
      driveKeysUrl: keysFileUrl ?? channel.driveKeysUrl,
    );
    await ChannelService.instance.updateChannel(next);
    await next.broadcastGossipMeta();
  }

  Future<void> _decryptAndImport(
      String channelId, int rev, Uint8List sealed) async {
    final applied = await _appliedRev(channelId);
    if (rev <= applied) return;
    final key = await _readSymKeyBytes(channelId);
    if (key == null) {
      _pendingDecryptByChannel[channelId] =
          _PendingDecrypt(rev: rev, sealed: sealed);
      return;
    }
    final plain =
        await CryptoService.instance.openSymmetric(sealed, key);
    if (plain == null) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (json['type'] != 'rlink_channel_backup') return;
    final jr = (json['rev'] as num?)?.toInt();
    if (jr == null || jr != rev) return;
    final channelIdJ = json['channelId'] as String?;
    if (channelIdJ != channelId) return;
    await ChannelService.instance.importChannelBackupSnapshot(channelId, json);
    await _setAppliedRev(channelId, rev);
    if (kDebugMode) {
      debugPrint('[RLINK][ChBak] Imported rev=$rev channel=$channelId');
    }
  }

  Future<void> onKeyPacket(GossipPacket packet) async {
    final cid = packet.payload['cid'] as String?;
    final emRaw = packet.payload['em'];
    if (cid == null || emRaw is! Map) return;
    try {
      final em = EncryptedMessage.fromJson(Map<String, dynamic>.from(emRaw));
      final plain = await CryptoService.instance.decryptMessage(em);
      if (plain == null) return;
      final bytes = base64Decode(plain);
      if (bytes.length != 32) return;
      await _writeSymKeyBytes(cid, Uint8List.fromList(bytes));
      final pend = _pendingDecryptByChannel.remove(cid);
      if (pend != null) {
        await _decryptAndImport(cid, pend.rev, pend.sealed);
      }
    } catch (_) {}
  }

  Future<void> onMetaPacket(GossipPacket packet) async {
    final cid = packet.payload['cid'] as String?;
    final rev = (packet.payload['r'] as num?)?.toInt();
    final n = (packet.payload['n'] as num?)?.toInt();
    final from = packet.payload['from'] as String?;
    final mid = packet.payload['mid'] as String?;
    if (cid == null || rev == null || n == null || from == null || mid == null) {
      return;
    }
    if (n <= 0 || n > 200000) return;

    final my = CryptoService.instance.publicKeyHex;
    if (my.isEmpty) return;
    if (from == my) return;

    final ch = await ChannelService.instance.getChannel(cid);
    if (ch == null) return;
    if (ch.adminId != from) return;
    if (!ch.subscriberIds.contains(my) && ch.adminId != my) return;

    final applied = await _appliedRev(cid);
    if (rev <= applied) return;

    _assemblies[mid] = _BakAssembly(channelId: cid, rev: rev, total: n);
  }

  Future<void> onChunkPacket(GossipPacket packet) async {
    final mid = packet.payload['mid'] as String?;
    final idx = (packet.payload['i'] as num?)?.toInt();
    final d = packet.payload['d'] as String?;
    if (mid == null || idx == null || idx < 0 || d == null || d.isEmpty) {
      return;
    }

    final asm = _assemblies[mid];
    if (asm == null) return;
    if (idx >= asm.total) return;

    try {
      asm.parts[idx] = Uint8List.fromList(base64Decode(d));
    } catch (_) {
      return;
    }

    if (asm.parts.length != asm.total) return;
    for (var i = 0; i < asm.total; i++) {
      if (!asm.parts.containsKey(i)) return;
    }

    final ordered = BytesBuilder();
    for (var i = 0; i < asm.total; i++) {
      ordered.add(asm.parts[i]!);
    }
    _assemblies.remove(mid);

    await _decryptAndImport(asm.channelId, asm.rev, ordered.toBytes());
  }

  /// Скачивает зашифрованный снимок по публичной ссылке [channel.driveFileUrl] и импортирует историю.
  /// Возвращает true при успешном импорте. Не требует авторизации в Google — файл публичный.
  /// Если локального ключа нет — пытается получить его из файла ключей [channel.driveKeysUrl].
  /// [onStep] вызывается при смене этапа — для UI-индикаторов.
  Future<bool> restoreFromDriveUrl(Channel channel, {void Function(String)? onStep}) async {
    final url = channel.driveFileUrl;
    if (url == null || url.isEmpty) return false;

    onStep?.call('Проверка ключа расшифровки…');
    var key = await _readSymKeyBytes(channel.id);

    // If no local key, try fetching it from the public keys file.
    if (key == null) {
      key = await _fetchKeyFromKeysFile(channel, onStep: onStep);
      if (key == null) {
        debugPrint('[RLINK][ChBak] restoreFromDriveUrl: no sym key for ${channel.id}');
        return false;
      }
    }

    try {
      onStep?.call('Скачивание из Google Drive…');
      debugPrint('[RLINK][ChBak] restoreFromDriveUrl: fetching ${url.substring(0, url.length.clamp(0, 60))}…');
      final dio = Dio();
      final response = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes, receiveTimeout: const Duration(seconds: 120)),
      );
      if (response.statusCode != 200 || response.data == null) {
        debugPrint('[RLINK][ChBak] restoreFromDriveUrl: HTTP ${response.statusCode}');
        return false;
      }
      final sealed = Uint8List.fromList(response.data!);
      onStep?.call('Расшифровка данных…');
      await _decryptAndImport(channel.id, channel.driveBackupRev, sealed);
      onStep?.call('Применение истории…');
      debugPrint('[RLINK][ChBak] restoreFromDriveUrl: import done (${sealed.length} bytes)');
      return true;
    } catch (e, st) {
      debugPrint('[RLINK][ChBak] restoreFromDriveUrl failed: $e\n$st');
      return false;
    }
  }

  /// Скачивает публичный JSON-файл ключей, находит запись для текущего пользователя,
  /// расшифровывает симметричный ключ и сохраняет его локально.
  Future<Uint8List?> _fetchKeyFromKeysFile(Channel channel, {void Function(String)? onStep}) async {
    final keysUrl = channel.driveKeysUrl;
    if (keysUrl == null || keysUrl.isEmpty) return null;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return null;
    try {
      onStep?.call('Получение ключа расшифровки…');
      debugPrint('[RLINK][ChBak] fetching keys file for ${channel.id}');
      final dio = Dio();
      final response = await dio.get<String>(
        keysUrl,
        options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 30)),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      final parsed = jsonDecode(response.data!) as Map<String, dynamic>;
      final keys = parsed['keys'] as Map<String, dynamic>?;
      if (keys == null) return null;
      final myEntry = keys[myId];
      if (myEntry is! Map) return null;
      final em = EncryptedMessage.fromJson(Map<String, dynamic>.from(myEntry));
      final plain = await CryptoService.instance.decryptMessage(em);
      if (plain == null) return null;
      final bytes = base64Decode(plain);
      if (bytes.length != 32) return null;
      final key = Uint8List.fromList(bytes);
      await _writeSymKeyBytes(channel.id, key);
      debugPrint('[RLINK][ChBak] key recovered from keys file for ${channel.id}');
      return key;
    } catch (e, st) {
      debugPrint('[RLINK][ChBak] _fetchKeyFromKeysFile failed: $e\n$st');
      return null;
    }
  }
}

class _PendingDecrypt {
  final int rev;
  final Uint8List sealed;

  _PendingDecrypt({required this.rev, required this.sealed});
}

class _BakAssembly {
  final String channelId;
  final int rev;
  final int total;
  final Map<int, Uint8List> parts = {};

  _BakAssembly({
    required this.channelId,
    required this.rev,
    required this.total,
  });
}
