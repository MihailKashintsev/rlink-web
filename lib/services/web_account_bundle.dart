import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_kv_store.dart';
import 'runtime_platform.dart';
import 'web_state_store.dart';

/// Single JSON blob for web/Tilda iframe: reduces torn writes and survives
/// flaky first-frame bridge reads by mirroring to SharedPreferences + KV.
const _bundleLogicalKey = 'rlink_account_bundle_v1';

const _prefsPrefix = 'rlink_account_v2_';

/// Same logical keys as [CryptoService] / [ProfileService].
const kMeshIdentityPrivate = 'mesh_identity_private';
const kMeshIdentityPublic = 'mesh_identity_public';
const kMeshX25519Private = 'mesh_x25519_private';
const kMeshX25519Public = 'mesh_x25519_public';
const kUserProfile = 'rlink_user_profile';

class WebAccountBundle {
  WebAccountBundle._();

  static Future<String?> _prefsRead(String logicalKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_prefsPrefix$logicalKey');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _prefsWrite(String logicalKey, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefsPrefix$logicalKey', value);
    } catch (_) {}
  }

  /// One-shot read: web bridge/localStorage → prefs mirror → durable KV.
  static Future<String?> layeredRead(String logicalKey) async {
    if (!RuntimePlatform.isWeb) return null;
    final w = await readWebState(logicalKey);
    if (w != null && w.isNotEmpty) return w;
    final p = await _prefsRead(logicalKey);
    if (p != null && p.isNotEmpty) {
      await writeWebState(logicalKey, p);
      return p;
    }
    final d = await AccountKvStore.read(logicalKey);
    if (d != null && d.isNotEmpty) {
      await writeWebState(logicalKey, d);
      await _prefsWrite(logicalKey, d);
      return d;
    }
    return null;
  }

  static Future<void> layeredWrite(String logicalKey, String value) async {
    if (!RuntimePlatform.isWeb) return;
    await writeWebState(logicalKey, value);
    await AccountKvStore.write(logicalKey, value);
    await _prefsWrite(logicalKey, value);
  }

  static Map<String, dynamic>? _tryDecodeBundle(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if ((j['v'] as num?)?.toInt() != 1) return null;
      return j;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _validateCryptoPayload(Map<String, dynamic> j) async {
    try {
      final edPr = j['edPr'] as String?;
      final edPu = j['edPu'] as String?;
      final xPr = j['xPr'] as String?;
      final xPu = j['xPu'] as String?;
      if (edPr == null ||
          edPu == null ||
          xPr == null ||
          xPu == null ||
          edPr.isEmpty ||
          edPu.isEmpty ||
          xPr.isEmpty ||
          xPu.isEmpty) {
        return false;
      }
      final edPriv = base64.decode(edPr);
      final edPub = base64.decode(edPu);
      final xPriv = base64.decode(xPr);
      final xPub = base64.decode(xPu);
      if (edPriv.isEmpty || edPub.isEmpty || xPriv.isEmpty || xPub.isEmpty) {
        return false;
      }
      final edKp = SimpleKeyPairData(
        edPriv,
        publicKey: SimplePublicKey(edPub, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
      final derivedEd = await edKp.extractPublicKey();
      if (!_bytesEq(derivedEd.bytes, edPub)) return false;

      final xKp = SimpleKeyPairData(
        xPriv,
        publicKey: SimplePublicKey(xPub, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
      final derivedX = await xKp.extractPublicKey();
      if (!_bytesEq(derivedX.bytes, xPub)) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _bytesEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<String?> _readRawBundleAllSources() async {
    String? raw = await readWebState(_bundleLogicalKey);
    raw ??= await _prefsRead(_bundleLogicalKey);
    raw ??= await AccountKvStore.read(_bundleLogicalKey);
    return (raw != null && raw.isNotEmpty) ? raw : null;
  }

  /// Cold start in iframe: bridge can answer late — retry before giving up.
  static Future<Map<String, dynamic>?> loadValidatedBundleWithRetries({
    int maxAttempts = 10,
  }) async {
    if (!RuntimePlatform.isWeb) return null;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final raw = await _readRawBundleAllSources();
      if (raw != null) {
        final j = _tryDecodeBundle(raw);
        if (j != null && await _validateCryptoPayload(j)) {
          return j;
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 80 + attempt * 60));
    }
    return null;
  }

  static Future<void> persistBundle({
    required String edPrivB64,
    required String edPubB64,
    required String xPrivB64,
    required String xPubB64,
    String? profileJson,
  }) async {
    if (!RuntimePlatform.isWeb) return;
    var prof = profileJson;
    if (prof == null || prof.isEmpty) {
      final raw = await _readRawBundleAllSources();
      if (raw != null) {
        try {
          final ej = jsonDecode(raw) as Map<String, dynamic>;
          final p = ej['prof'] as String?;
          if (p != null && p.isNotEmpty) prof = p;
        } catch (_) {}
      }
    }
    final j = <String, dynamic>{
      'v': 1,
      'edPr': edPrivB64,
      'edPu': edPubB64,
      'xPr': xPrivB64,
      'xPu': xPubB64,
      if (prof != null && prof.isNotEmpty) 'prof': prof,
    };
    final raw = jsonEncode(j);
    await writeWebState(_bundleLogicalKey, raw);
    await AccountKvStore.write(_bundleLogicalKey, raw);
    await _prefsWrite(_bundleLogicalKey, raw);
  }

  static Future<String?> profileJsonFromBundle() async {
    if (!RuntimePlatform.isWeb) return null;
    final j = await loadValidatedBundleWithRetries(maxAttempts: 4);
    final p = j?['prof'] as String?;
    if (p != null && p.isNotEmpty) return p;
    return null;
  }

  /// After profile save: re-read keys from layered storage and refresh bundle.
  static Future<void> mergeProfileIntoBundle(String profileEncoded) async {
    if (!RuntimePlatform.isWeb) return;
    final edPr = await layeredRead(kMeshIdentityPrivate);
    final edPu = await layeredRead(kMeshIdentityPublic);
    final xPr = await layeredRead(kMeshX25519Private);
    final xPu = await layeredRead(kMeshX25519Public);
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
    await persistBundle(
      edPrivB64: edPr,
      edPubB64: edPu,
      xPrivB64: xPr,
      xPubB64: xPu,
      profileJson: profileEncoded,
    );
  }
}
