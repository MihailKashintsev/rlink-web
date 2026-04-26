import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
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
    final json = impl.buildIdentityExportJson(
      edPrivB64: edPr,
      edPubB64: edPu,
      xPrivB64: xPr,
      xPubB64: xPu,
      profileJson: prof,
    );
    await impl.writeIdentityJsonToOpfs(json);
  }

  static Future<void> exportIdentityKeyDownload() async {
    if (!RuntimePlatform.isWeb) return;
    await syncIdentitySnapshotToOpfs();
    final raw = await impl.readIdentityJsonFromOpfs();
    if (raw == null || raw.isEmpty) return;
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
