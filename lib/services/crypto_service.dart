import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final _ed25519 = Ed25519();
  final _x25519 = X25519();
  final _chacha = Chacha20.poly1305Aead();

  late SimpleKeyPair _identityKeyPair;

  /// X25519 keypair для ECDH — хранится отдельно от Ed25519 идентити.
  /// Это обязательно: Ed25519 байты нельзя напрямую использовать как X25519.
  late SimpleKeyPair _x25519IdentityKeyPair;

  /// Публичный ключ как hex — это ID пользователя (аналог номера телефона)
  late String publicKeyHex;

  /// X25519 публичный ключ в base64 — передаётся в profile broadcast
  /// и используется получателем для ECDH при шифровании сообщений.
  late String x25519PublicKeyBase64;

  /// Инициализация: загружаем или генерируем Ed25519 + X25519 keypairs
  Future<void> init() async {
    // ── Ed25519 identity keypair ──────────────────────────────────
    final storedPrivate = await _storage.read(key: _keyPrivate);
    final storedPublic = await _storage.read(key: _keyPublic);

    if (storedPrivate != null && storedPublic != null) {
      final privateBytes = base64.decode(storedPrivate);
      final publicBytes = base64.decode(storedPublic);
      _identityKeyPair = SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
    } else {
      _identityKeyPair = await _ed25519.newKeyPair();
      final privateBytes = await _identityKeyPair.extractPrivateKeyBytes();
      final publicKey = await _identityKeyPair.extractPublicKey();
      await _storage.write(
          key: _keyPrivate, value: base64.encode(privateBytes));
      await _storage.write(
          key: _keyPublic, value: base64.encode(publicKey.bytes));
    }

    final pubKey = await _identityKeyPair.extractPublicKey();
    publicKeyHex = _bytesToHex(pubKey.bytes);

    // ── X25519 ECDH keypair ───────────────────────────────────────
    final storedX25519Priv = await _storage.read(key: _keyX25519Private);
    final storedX25519Pub = await _storage.read(key: _keyX25519Public);

    if (storedX25519Priv != null && storedX25519Pub != null) {
      final privBytes = base64.decode(storedX25519Priv);
      final pubBytes = base64.decode(storedX25519Pub);
      _x25519IdentityKeyPair = SimpleKeyPairData(
        privBytes,
        publicKey: SimplePublicKey(pubBytes, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      );
    } else {
      _x25519IdentityKeyPair = await _x25519.newKeyPair();
      final privBytes =
          await _x25519IdentityKeyPair.extractPrivateKeyBytes();
      final pubKeyX = await _x25519IdentityKeyPair.extractPublicKey();
      await _storage.write(
          key: _keyX25519Private, value: base64.encode(privBytes));
      await _storage.write(
          key: _keyX25519Public, value: base64.encode(pubKeyX.bytes));
    }

    final x25519Pub = await _x25519IdentityKeyPair.extractPublicKey();
    x25519PublicKeyBase64 = base64.encode(x25519Pub.bytes);
  }

  /// Возвращает байты Ed25519 публичного ключа (для BLE advertising)
  Future<Uint8List> getPublicKeyBytes() async {
    final pub = await _identityKeyPair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  // ─── Шифрование сообщений ─────────────────────────────────

  /// Шифрует [plaintext] для получателя с X25519 ключом [recipientX25519KeyBase64].
  ///
  /// Использует эфемерный X25519 keypair + ECDH + ChaCha20-Poly1305.
  /// Поля кодируются в base64 для компактности (укладывается в BLE MTU ~490 байт).
  Future<EncryptedMessage> encryptMessage({
    required String plaintext,
    required String recipientX25519KeyBase64,
  }) async {
    // 1. Эфемерный X25519 keypair для этого сообщения
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    // 2. X25519 ECDH с X25519 ключом получателя → общий секрет
    final recipientX25519Key = SimplePublicKey(
      base64.decode(recipientX25519KeyBase64),
      type: KeyPairType.x25519,
    );
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientX25519Key,
    );

    // 3. ChaCha20-Poly1305 шифрование
    final nonce = _chacha.newNonce();
    final secretBox = await _chacha.encrypt(
      plaintext.codeUnits,
      secretKey: sharedSecret,
      nonce: nonce,
    );

    return EncryptedMessage(
      senderPublicKey: publicKeyHex,
      ephemeralPublicKey: base64.encode(ephemeralPublicKey.bytes),
      nonce: base64.encode(secretBox.nonce),
      cipherText: base64.encode(secretBox.cipherText),
      mac: base64.encode(secretBox.mac.bytes),
      signature: '', // подпись убрана для экономии 88+ байт в BLE MTU
    );
  }

  /// Расшифровывает [message] адресованное нам.
  /// Использует наш X25519 identity keypair.
  Future<String?> decryptMessage(EncryptedMessage message) async {
    try {
      final ephemeralBytes = base64.decode(message.ephemeralPublicKey);
      final nonceBytes = base64.decode(message.nonce);
      final cipherBytes = base64.decode(message.cipherText);
      final macBytes = base64.decode(message.mac);

      // X25519 ECDH: наш X25519 приватный ключ + эфемерный публичный ключ
      final ephemeralPublicKey =
          SimplePublicKey(ephemeralBytes, type: KeyPairType.x25519);
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _x25519IdentityKeyPair,
        remotePublicKey: ephemeralPublicKey,
      );

      // Расшифровываем
      final secretBox = SecretBox(
        cipherBytes,
        nonce: nonceBytes,
        mac: Mac(macBytes),
      );
      final plainBytes =
          await _chacha.decrypt(secretBox, secretKey: sharedSecret);
      return String.fromCharCodes(plainBytes);
    } catch (e) {
      return null;
    }
  }

  // ─── Утилиты ─────────────────────────────────────────────

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Зашифрованное сообщение — то, что реально летит по BLE в 'msg' пакете.
/// Все бинарные поля кодируются в base64 для компактности.
class EncryptedMessage {
  final String senderPublicKey; // Ed25519 публичный ключ отправителя hex (его ID)
  final String ephemeralPublicKey; // X25519 эфемерный ключ base64 (для ECDH)
  final String nonce; // 12 байт base64
  final String cipherText; // base64
  final String mac; // Poly1305 тег base64
  final String signature; // не используется, оставлен для API совместимости

  const EncryptedMessage({
    required this.senderPublicKey,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    this.signature = '',
  });

  factory EncryptedMessage.fromJson(Map<String, dynamic> j) => EncryptedMessage(
        senderPublicKey: j['spk'] as String? ?? '',
        ephemeralPublicKey: j['epk'] as String? ?? '',
        nonce: j['n'] as String? ?? '',
        cipherText: j['ct'] as String? ?? '',
        mac: j['mac'] as String? ?? '',
      );

  /// Сериализация без подписи — умещается в BLE MTU ~490 байт.
  Map<String, dynamic> toJson() => {
        'spk': senderPublicKey,
        'epk': ephemeralPublicKey,
        'n': nonce,
        'ct': cipherText,
        'mac': mac,
      };
}
