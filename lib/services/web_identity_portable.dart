import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import '../models/channel.dart';
import '../models/group.dart';
import 'chat_storage_service.dart';
import 'channel_service.dart';
import 'group_service.dart';
import 'runtime_platform.dart';
import 'web_account_bundle.dart';
import 'web_identity_io_stub.dart'
    if (dart.library.html) 'web_identity_opfs_web.dart' as impl;

/// Web-only: OPFS mirror + downloadable JSON identity backup.
abstract final class WebIdentityPortable {
  WebIdentityPortable._();

  static String _publicKeyHexFromEdPubB64(String edPubB64) {
    final bytes = base64.decode(edPubB64);
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Returns true if a new minimal profile was written into [flat].
  static bool _injectMinimalProfileIfNeeded(Map<String, String> flat) {
    final prof = flat[kUserProfile];
    if (prof != null &&
        prof.isNotEmpty &&
        UserProfile.tryDecode(prof) != null) {
      return false;
    }
    final rng = Random();
    final minimal = UserProfile(
      publicKeyHex: _publicKeyHexFromEdPubB64(flat[kMeshIdentityPublic]!),
      nickname: 'User',
      avatarColor:
          UserProfile.avatarColors[rng.nextInt(UserProfile.avatarColors.length)],
      avatarEmoji:
          UserProfile.avatarEmojis[rng.nextInt(UserProfile.avatarEmojis.length)],
    );
    flat[kUserProfile] = minimal.encode();
    debugPrint('[WebIdentity] Injected minimal profile (missing/invalid prof)');
    return true;
  }

  /// If normal web storage is empty, restore keys + profile from OPFS backup.
  static Future<void> hydrateLayeredStorageFromOpfsIfMissing() async {
    if (!RuntimePlatform.isWeb) return;
    final existing =
        await WebAccountBundle.layeredRead(kMeshIdentityPrivate);
    if (existing != null && existing.isNotEmpty) return;

    final raw = await impl.readIdentityJsonFromOpfs();
    if (raw == null || raw.isEmpty) return;
    final m = impl.parseIdentityExport(raw);
    if (m == null) return;

    final flat = Map<String, String>.from(m);
    final opfsNeedsRewrite = _injectMinimalProfileIfNeeded(flat);
    for (final e in flat.entries) {
      await WebAccountBundle.layeredWrite(e.key, e.value);
    }
    await WebAccountBundle.persistBundle(
      edPrivB64: flat[kMeshIdentityPrivate]!,
      edPubB64: flat[kMeshIdentityPublic]!,
      xPrivB64: flat[kMeshX25519Private]!,
      xPubB64: flat[kMeshX25519Public]!,
      profileJson: flat[kUserProfile],
    );
    if (opfsNeedsRewrite) {
      await impl.writeIdentityJsonToOpfs(
        impl.buildIdentityExportJson(
          edPrivB64: flat[kMeshIdentityPrivate]!,
          edPubB64: flat[kMeshIdentityPublic]!,
          xPrivB64: flat[kMeshX25519Private]!,
          xPubB64: flat[kMeshX25519Public]!,
          profileJson: flat[kUserProfile],
          settingsJson: flat[kAppSettingsBackup],
          channelsJson: flat[kChannelsBackup],
          groupsJson: flat[kGroupsBackup],
          chatsJson: flat[kChatsBackup],
        ),
      );
    }
  }

  /// Keep OPFS copy aligned with layered storage (survives localStorage wipes).
  static Future<void> syncIdentitySnapshotToOpfs(
      {String? profileJsonOverride}) async {
    if (!RuntimePlatform.isWeb) return;
    final edPr =
        await WebAccountBundle.layeredRead(kMeshIdentityPrivate);
    final edPu =
        await WebAccountBundle.layeredRead(kMeshIdentityPublic);
    final xPr =
        await WebAccountBundle.layeredRead(kMeshX25519Private);
    final xPu =
        await WebAccountBundle.layeredRead(kMeshX25519Public);
    if (edPr == null ||
        edPu == null ||
        xPr == null ||
        xPu == null ||
        edPr.isEmpty ||
        edPu.isEmpty ||
        xPr.isEmpty ||
        xPu.isEmpty) {
      return;
    }
    var prof = profileJsonOverride;
    prof ??= await WebAccountBundle.layeredRead(kUserProfile);
    final stg = await WebAccountBundle.layeredRead(kAppSettingsBackup);
    final chs = await _encodeChannelsBackupJson();
    final grs = await _encodeGroupsBackupJson();
    final cht = await _encodeChatsBackupJson();
    final json = impl.buildIdentityExportJson(
      edPrivB64: edPr,
      edPubB64: edPu,
      xPrivB64: xPr,
      xPubB64: xPu,
      profileJson: prof,
      settingsJson: stg,
      channelsJson: chs,
      groupsJson: grs,
      chatsJson: cht,
    );
    await impl.writeIdentityJsonToOpfs(json);
  }

  static Future<String?> _encodeChannelsBackupJson() async {
    try {
      final channels = await ChannelService.instance.getChannels();
      final payload = channels.map((c) => c.toJson()).toList();
      final encoded = jsonEncode(payload);
      await WebAccountBundle.layeredWrite(kChannelsBackup, encoded);
      return encoded;
    } catch (_) {
      return await WebAccountBundle.layeredRead(kChannelsBackup);
    }
  }

  static Future<String?> _encodeGroupsBackupJson() async {
    try {
      final groups = await GroupService.instance.getGroups();
      final payload = groups.map((g) => g.toJson()).toList();
      final encoded = jsonEncode(payload);
      await WebAccountBundle.layeredWrite(kGroupsBackup, encoded);
      return encoded;
    } catch (_) {
      return await WebAccountBundle.layeredRead(kGroupsBackup);
    }
  }

  static Future<void> restoreStructuredDataFromBackupIfPresent() async {
    if (!RuntimePlatform.isWeb) return;
    try {
      final chatRaw = await WebAccountBundle.layeredRead(kChatsBackup);
      if (chatRaw != null && chatRaw.isNotEmpty) {
        final decoded = jsonDecode(chatRaw);
        if (decoded is Map) {
          await ChatStorageService.instance
              .importBackupSnapshot(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {}
    try {
      final chRaw = await WebAccountBundle.layeredRead(kChannelsBackup);
      if (chRaw != null && chRaw.isNotEmpty) {
        final decoded = jsonDecode(chRaw);
        if (decoded is List) {
          final list = decoded
              .whereType<Map>()
              .map((e) => Channel.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          await ChannelService.instance.upsertChannelsFromBackup(list);
        }
      }
    } catch (_) {}
    try {
      final grRaw = await WebAccountBundle.layeredRead(kGroupsBackup);
      if (grRaw != null && grRaw.isNotEmpty) {
        final decoded = jsonDecode(grRaw);
        if (decoded is List) {
          final list = decoded
              .whereType<Map>()
              .map((e) => Group.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          await GroupService.instance.upsertGroupsFromBackup(list);
        }
      }
    } catch (_) {}
  }

  static Future<String?> _encodeChatsBackupJson() async {
    try {
      final snap = await ChatStorageService.instance.exportBackupSnapshot();
      final encoded = jsonEncode(snap);
      await WebAccountBundle.layeredWrite(kChatsBackup, encoded);
      return encoded;
    } catch (_) {
      return await WebAccountBundle.layeredRead(kChatsBackup);
    }
  }

  static Future<void> exportIdentityKeyDownload() async {
    if (!RuntimePlatform.isWeb) return;
    await syncIdentitySnapshotToOpfs();
    final raw = await impl.readIdentityJsonFromOpfs();
    if (raw == null || raw.isEmpty) return;
    final approved = await impl.confirmIdentityDownloadPrompt();
    if (!approved) return;
    final edPu = await WebAccountBundle.layeredRead(kMeshIdentityPublic);
    var short = 'id';
    if (edPu != null && edPu.isNotEmpty) {
      try {
        final bytes = base64.decode(edPu);
        final hex =
            bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex.length >= 8) short = hex.substring(0, 8);
      } catch (_) {}
    }
    impl.triggerIdentityDownload(raw, short);
  }

  /// Returns true if a valid backup was applied. [reloadAfter] refreshes the tab.
  static Future<bool> importIdentityKeyFromUserFile(
      {bool reloadAfter = true}) async {
    if (!RuntimePlatform.isWeb) return false;
    final raw = await impl.pickAndReadIdentityBackupFile();
    if (raw == null || raw.isEmpty) return false;
    final m = impl.parseIdentityExport(raw);
    if (m == null) return false;
    final flat = Map<String, String>.from(m);
    _injectMinimalProfileIfNeeded(flat);
    for (final e in flat.entries) {
      await WebAccountBundle.layeredWrite(e.key, e.value);
    }
    await WebAccountBundle.persistBundle(
      edPrivB64: flat[kMeshIdentityPrivate]!,
      edPubB64: flat[kMeshIdentityPublic]!,
      xPrivB64: flat[kMeshX25519Private]!,
      xPubB64: flat[kMeshX25519Public]!,
      profileJson: flat[kUserProfile],
    );
    final jsonOut = impl.buildIdentityExportJson(
      edPrivB64: flat[kMeshIdentityPrivate]!,
      edPubB64: flat[kMeshIdentityPublic]!,
      xPrivB64: flat[kMeshX25519Private]!,
      xPubB64: flat[kMeshX25519Public]!,
      profileJson: flat[kUserProfile],
      settingsJson: flat[kAppSettingsBackup],
      channelsJson: flat[kChannelsBackup],
      groupsJson: flat[kGroupsBackup],
      chatsJson: flat[kChatsBackup],
    );
    await impl.writeIdentityJsonToOpfs(jsonOut);
    if (reloadAfter) {
      await WebAccountBundle.layeredWrite(kRlinkPostKeyImportFlag, '1');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      impl.reloadWebApp();
    }
    return true;
  }
}
