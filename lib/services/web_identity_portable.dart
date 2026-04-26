import 'dart:convert';

import 'runtime_platform.dart';
import 'web_account_bundle.dart';
import 'web_identity_io_stub.dart'
    if (dart.library.html) 'web_identity_opfs_web.dart' as impl;

/// Web-only: OPFS mirror + downloadable JSON identity backup.
abstract final class WebIdentityPortable {
  WebIdentityPortable._();

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

    for (final e in m.entries) {
      await WebAccountBundle.layeredWrite(e.key, e.value);
    }
    await WebAccountBundle.persistBundle(
      edPrivB64: m[kMeshIdentityPrivate]!,
      edPubB64: m[kMeshIdentityPublic]!,
      xPrivB64: m[kMeshX25519Private]!,
      xPubB64: m[kMeshX25519Public]!,
      profileJson: m[kUserProfile],
    );
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
    for (final e in m.entries) {
      await WebAccountBundle.layeredWrite(e.key, e.value);
    }
    await WebAccountBundle.persistBundle(
      edPrivB64: m[kMeshIdentityPrivate]!,
      edPubB64: m[kMeshIdentityPublic]!,
      xPrivB64: m[kMeshX25519Private]!,
      xPubB64: m[kMeshX25519Public]!,
      profileJson: m[kUserProfile],
    );
    await impl.writeIdentityJsonToOpfs(raw);
    if (reloadAfter) impl.reloadWebApp();
    return true;
  }
}
