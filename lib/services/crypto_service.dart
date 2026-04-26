import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'runtime_platform.dart';
import 'web_account_bundle.dart';
import 'web_identity_portable.dart';

/// Хранит Ed25519 keypair пользователя (его "аккаунт") и отдельный X25519
/// keypair для ECDH шифрования сообщений.
///
/// Схема:
///   Identity  → Ed25519  (публичный ID пользователя)
///   X25519    → X25519   (ECDH key exchange per-message)
///   Payload   → ChaCha20-Poly1305 (AEAD шифрование)
class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  static const _keyPrivate = 'mesh_identity_private';
  static const _keyPublic = 'mesh_identity_public';
  static const _keyX25519Private = 'mesh_x25519_private';
  static const _keyX25519Public = 'mesh_x25519_public';

  // On desktop (macOS/Windows/Linux) Keychain/secure storage isn't reliable;
  // use SharedPreferences as fallback (keys are still generated fresh each time
  // on desktop and persisted across launches).
  static bool get _isMobile => RuntimePlatform.isIos || RuntimePlatform.isAndroid;

  final _secureSt = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  Future<String?> _read(String key) async {
    if (RuntimePlatform.isWeb) {
      return WebAccountBundle.layeredRead(key);
    }
    if (_isMobile) return _secureSt.read(key: key);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> _write(String key, String value) async {
    if (RuntimePlatform.isWeb) {
      await WebAccountBundle.layeredWrite(key, value);
      return;
    }
    if (_isMobile) {
      await _secureSt.write(key: key, value: value);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _chacha = Chacha20.poly1305Aead();

  late SimpleKeyPair _identityKeyPair;

  /// X25519 keypair для ECDH — хранится отдельно от Ed25519 идентити.
  /// Это обязательно: Ed25519 байты нельзя напрямую использовать как X25519.
  late SimpleKeyPair _x25519IdentityKeyPair;

  /// Публичный ключ как hex — это ID пользователя (аналог номера телефона)
  String publicKeyHex = '';

  /// X25519 публичный ключ в base64 — передаётся в profile broadcast
  /// и используется получателем для ECDH при шифровании сообщений.
  String x25519PublicKeyBase64 = '';

  /// Инициализация: загружаем или генерируем Ed25519 + X25519 keypairs
  Future<void> init() async {
    // ── Ed25519 identity keypair ──────────────────────────────────
    var restoredEd = false;
    var restoredX = false;

    if (RuntimePlatform.isWeb) {
      final bundle = await WebAccountBundle.loadValidatedBundleWithRetries();
      if (bundle != null) {
        try {
          final edPr = bundle['edPr'] as String;
          final edPu = bundle['edPu'] as String;
          final xPr = bundle['xPr'] as String;
          final xPu = bundle['xPu'] as String;
          _identityKeyPair = SimpleKeyPairData(
            base64.decode(edPr),
            publicKey:
                SimplePublicKey(base64.decode(edPu), type: KeyPairType.ed25519),
            type: KeyPairType.ed25519,
          );
          restoredEd = true;
          _x25519IdentityKeyPair = SimpleKeyPairData(
            base64.decode(xPr),
            publicKey:
                SimplePublicKey(base64.decode(xPu), type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
          restoredX = true;
          await WebAccountBundle.layeredWrite(_keyPrivate, edPr);
          await WebAccountBundle.layeredWrite(_keyPublic, edPu);
          await WebAccountBundle.layeredWrite(_keyX25519Private, xPr);
          await WebAccountBundle.layeredWrite(_keyX25519Public, xPu);
        } catch (e) {
          debugPrint('[Crypto] Web bundle restore failed: $e');
          restoredEd = false;
          restoredX = false;
        }
      }
    }

    if (!restoredEd) {
      try {
        final storedPrivate = await _read(_keyPrivate);
        final storedPublic = await _read(_keyPublic);
        if (storedPrivate != null &&
            storedPublic != null &&
            storedPrivate.isNotEmpty &&
            storedPublic.isNotEmpty) {
          final privateBytes = base64.decode(storedPrivate);
          final publicBytes = base64.decode(storedPublic);
          _identityKeyPair = SimpleKeyPairData(
            privateBytes,
            publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
            type: KeyPairType.ed25519,
          );
          restoredEd = true;
        }
      } catch (e) {
        debugPrint('[Crypto] Failed to restore Ed25519 keys, regenerating: $e');
      }
    }
    if (!restoredEd) {
      _identityKeyPair = await _ed25519.newKeyPair();
      final privateBytes = await _identityKeyPair.extractPrivateKeyBytes();
      final publicKey = await _identityKeyPair.extractPublicKey();
      await _write(_keyPrivate, base64.encode(privateBytes));
      await _write(_keyPublic, base64.encode(publicKey.bytes));
    }

    final pubKey = await _identityKeyPair.extractPublicKey();
    publicKeyHex = _bytesToHex(pubKey.bytes);

    // ── X25519 ECDH keypair ───────────────────────────────────────
    if (!restoredX) {
      try {
        final storedX25519Priv = await _read(_keyX25519Private);
        final storedX25519Pub = await _read(_keyX25519Public);
        if (storedX25519Priv != null &&
            storedX25519Pub != null &&
            storedX25519Priv.isNotEmpty &&
            storedX25519Pub.isNotEmpty) {
          final privBytes = base64.decode(storedX25519Priv);
          final pubBytes = base64.decode(storedX25519Pub);
          _x25519IdentityKeyPair = SimpleKeyPairData(
            privBytes,
            publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
          restoredX = true;
        }
      } catch (e) {
        debugPrint('[Crypto] Failed to restore X25519 keys, regenerating: $e');
      }
    }
    if (!restoredX) {
      _x25519IdentityKeyPair = await _x25519.newKeyPair();
      final privBytes = await _x25519IdentityKeyPair.extractPrivateKeyBytes();
      final pubKeyX = await _x25519IdentityKeyPair.extractPublicKey();
      await _write(_keyX25519Private, base64.encode(privBytes));
      await _write(_keyX25519Public, base64.encode(pubKeyX.bytes));
    }

    final x25519PubKey = await _x25519IdentityKeyPair.extractPublicKey();
    x25519PublicKeyBase64 = base64.encode(x25519PubKey.bytes);

    if (RuntimePlatform.isWeb) {
      try {
        final edPrivBytes = await _identityKeyPair.extractPrivateKeyBytes();
        final edPubKey = await _identityKeyPair.extractPublicKey();
        final xPrivBytes = await _x25519IdentityKeyPair.extractPrivateKeyBytes();
        final xPubKey = await _x25519IdentityKeyPair.extractPublicKey();
        await WebAccountBundle.persistBundle(
          edPrivB64: base64.encode(edPrivBytes),
          edPubB64: base64.encode(edPubKey.bytes),
          xPrivB64: base64.encode(xPrivBytes),
          xPubB64: base64.encode(xPubKey.bytes),
          profileJson: null,
        );
        unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
      } catch (e) {
        debugPrint('[Crypto] Web account bundle persist failed: $e');
      }
    }
  }

  /// Force-generates brand-new Ed25519 + X25519 keypairs and persists them.
  /// Called during a full app reset so the new session uses a fresh identity
  /// immediately — without waiting for the next cold start.
  Future<void> regenerateKeys() async {
    // Ed25519 identity
    _identityKeyPair = await _ed25519.newKeyPair();
    final priv = await _identityKeyPair.extractPrivateKeyBytes();
    final pub  = await _identityKeyPair.extractPublicKey();
    await _write(_keyPrivate, base64.encode(priv));
    await _write(_keyPublic,  base64.encode(pub.bytes));
    publicKeyHex = _bytesToHex(pub.bytes);

    // X25519 ECDH
    _x25519IdentityKeyPair = await _x25519.newKeyPair();
    final xPriv = await _x25519IdentityKeyPair.extractPrivateKeyBytes();
    final xPub  = await _x25519IdentityKeyPair.extractPublicKey();
    await _write(_keyX25519Private, base64.encode(xPriv));
    await _write(_keyX25519Public,  base64.encode(xPub.bytes));
    x25519PublicKeyBase64 = base64.encode(xPub.bytes);

    if (RuntimePlatform.isWeb) {
      try {
        await WebAccountBundle.persistBundle(
          edPrivB64: base64.encode(priv),
          edPubB64: base64.encode(pub.bytes),
          xPrivB64: base64.encode(xPriv),
          xPubB64: base64.encode(xPub.bytes),
          profileJson: null,
        );
      } catch (e) {
        debugPrint('[Crypto] Web bundle persist after regenerate: $e');
      }
      unawaited(WebIdentityPortable.syncIdentitySnapshotToOpfs());
    }

    debugPrint('[Crypto] Keys regenerated → ${publicKeyHex.substring(0, 8)}…');
  }

  // ── Шифрование ───────────────────────────────────────────────

  /// Шифрует plaintext для получателя с его X25519 публичным ключом base64.
  Future<EncryptedMessage> encryptMessage({
    required String plaintext,
    required String recipientX25519KeyBase64,
  }) async {
    final recipientPubKeyBytes = base64.decode(recipientX25519KeyBase64);
    final recipientPubKey =
        SimplePublicKey(recipientPubKeyBytes, type: KeyPairType.x25519);

    // Ephemeral X25519 keypair для Forward Secrecy
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPubKey,
    );
    final sharedSecretBytes = await sharedSecret.extractBytes();

    // Derive 32-byte key via simple SHA-256-like truncation
    final derivedKey = SecretKey(sharedSecretBytes.sublist(0, 32));

    // Cryptographically secure random nonce (12 bytes for ChaCha20-Poly1305)
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final secretBox = await _chacha.encrypt(
      utf8.encode(plaintext),
      secretKey: derivedKey,
      nonce: nonce,
    );

    final ephemeralPubKey = await ephemeralKeyPair.extractPublicKey();

    debugPrint('[RLINK][Crypto] Encrypted: nonce=${base64.encode(nonce)}, ct=${secretBox.cipherText.length}b, mac=${secretBox.mac.bytes.length}b');

    return EncryptedMessage(
      senderPublicKey: publicKeyHex,
      ephemeralPublicKey: base64.encode(ephemeralPubKey.bytes),
      nonce: base64.encode(nonce),
      cipherText: base64.encode(secretBox.cipherText),
      mac: base64.encode(secretBox.mac.bytes),
      signature: '',
    );
  }

  /// Дешифрует сообщение, зашифрованное для нас.
  /// Симметричное AEAD (ChaCha20-Poly1305) для бэкапа канала и др. локальных блобов.
  Future<Uint8List> sealSymmetric(Uint8List plain, List<int> key32) async {
    if (key32.length != 32) {
      throw ArgumentError.value(key32.length, 'key32', 'expected 32 bytes');
    }
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final box = await _chacha.encrypt(
      plain,
      secretKey: SecretKey(key32),
      nonce: nonce,
    );
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List?> openSymmetric(Uint8List sealed, List<int> key32) async {
    if (key32.length != 32 || sealed.length < 12 + 16) return null;
    final nonce = sealed.sublist(0, 12);
    final mac = Mac(sealed.sublist(sealed.length - 16));
    final ct = sealed.sublist(12, sealed.length - 16);
    try {
      final box = SecretBox(ct, nonce: nonce, mac: mac);
      final out = await _chacha.decrypt(box, secretKey: SecretKey(key32));
      return Uint8List.fromList(out);
    } catch (_) {
      return null;
    }
  }

  Future<String?> decryptMessage(EncryptedMessage msg) async {
    try {
      final ephemeralPubKeyBytes = base64.decode(msg.ephemeralPublicKey);
      final ephemeralPubKey =
          SimplePublicKey(ephemeralPubKeyBytes, type: KeyPairType.x25519);

      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _x25519IdentityKeyPair,
        remotePublicKey: ephemeralPubKey,
      );
      final sharedSecretBytes = await sharedSecret.extractBytes();
      final derivedKey = SecretKey(sharedSecretBytes.sublist(0, 32));

      final nonce = base64.decode(msg.nonce);
      final cipherText = base64.decode(msg.cipherText);
      final mac = Mac(base64.decode(msg.mac));

      debugPrint('[RLINK][Crypto] Decrypt: epk=${msg.ephemeralPublicKey.substring(0, 8)}, nonce=${nonce.length}b, ct=${cipherText.length}b, mac=${mac.bytes.length}b');

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
      final plainBytes = await _chacha.decrypt(secretBox, secretKey: derivedKey);
      final result = utf8.decode(plainBytes);
      debugPrint('[RLINK][Crypto] Decrypt OK: ${result.substring(0, result.length.clamp(0, 20))}');
      return result;
    } catch (e) {
      debugPrint('[RLINK][Crypto] Decrypt FAILED: $e');
      return null;
    }
  }

  /// Симметричное шифрование на ключе, выведенном из приватного Ed25519 (только эта идентичность).
  /// Уходит в сеть как opaque blob — relay не может извлечь хэш пароля админки.
  Future<String> sealAdminPanelSync(String plaintext) async {
    final key = await _adminPanelSyncSecretKey();
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final box = await _chacha.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return jsonEncode({
      'n': base64.encode(nonce),
      'ct': base64.encode(box.cipherText),
      'm': base64.encode(box.mac.bytes),
    });
  }

  Future<String?> openAdminPanelSync(String sealedJson) async {
    try {
      final j = jsonDecode(sealedJson) as Map<String, dynamic>;
      final n = j['n'] as String?;
      final ct = j['ct'] as String?;
      final m = j['m'] as String?;
      if (n == null || ct == null || m == null) return null;
      final nonce = base64.decode(n);
      final cipherText = base64.decode(ct);
      final mac = Mac(base64.decode(m));
      final key = await _adminPanelSyncSecretKey();
      final plain = await _chacha.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
      );
      return utf8.decode(plain);
    } catch (e) {
      debugPrint('[Crypto] openAdminPanelSync failed: $e');
      return null;
    }
  }

  Future<SecretKey> _adminPanelSyncSecretKey() async {
    final priv = await _identityKeyPair.extractPrivateKeyBytes();
    final prefix = utf8.encode('rlink.admin_panel.sync.v1');
    final combined = <int>[...prefix, ...priv];
    final hash = await Sha256().hash(combined);
    return SecretKey(hash.bytes);
  }

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Ed25519-подпись UTF-8 строки (каталог публичных каналов на relay).
  Future<String> signUtf8Message(String message) async {
    final sig = await _ed25519.sign(
      utf8.encode(message),
      keyPair: _identityKeyPair,
    );
    return _bytesToHex(sig.bytes);
  }
}

class EncryptedMessage {
  final String senderPublicKey;
  final String ephemeralPublicKey;
  final String nonce;
  final String cipherText;
  final String mac;
  final String signature;

  const EncryptedMessage({
    required this.senderPublicKey,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    required this.signature,
  });

  Map<String, dynamic> toJson() => {
        'from': senderPublicKey,
        'epk': ephemeralPublicKey,
        'n': nonce,
        'ct': cipherText,
        'mac': mac,
        if (signature.isNotEmpty) 'sig': signature,
      };

  factory EncryptedMessage.fromJson(Map<String, dynamic> j) => EncryptedMessage(
        senderPublicKey: j['from'] as String? ?? '',
        ephemeralPublicKey: j['epk'] as String? ?? '',
        nonce: j['n'] as String? ?? '',
        cipherText: j['ct'] as String? ?? '',
        mac: j['mac'] as String? ?? '',
        signature: j['sig'] as String? ?? '',
      );
}
