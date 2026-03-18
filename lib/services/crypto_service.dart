import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Хранит Ed25519 keypair пользователя (его "аккаунт") и
/// предоставляет методы для шифрования/подписи сообщений.
///
/// Схема:
///   Identity  → Ed25519  (подпись сообщений + публичный ID)
///   Session   → X25519   (ECDH key exchange per-peer)
///   Payload   → ChaCha20-Poly1305 (AEAD шифрование)
class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  static const _keyPrivate = 'mesh_identity_private';
  static const _keyPublic  = 'mesh_identity_public';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final _ed25519    = Ed25519();
  final _x25519     = X25519();
  final _chacha     = Chacha20.poly1305Aead();

  late SimpleKeyPair _identityKeyPair;

  /// Публичный ключ как hex — это ID пользователя (аналог номера телефона)
  late String publicKeyHex;

  /// Инициализация: загружаем или генерируем keypair
  Future<void> init() async {
    final storedPrivate = await _storage.read(key: _keyPrivate);
    final storedPublic  = await _storage.read(key: _keyPublic);

    if (storedPrivate != null && storedPublic != null) {
      // Восстанавливаем из хранилища
      final privateBytes = base64.decode(storedPrivate);
      final publicBytes  = base64.decode(storedPublic);

      _identityKeyPair = SimpleKeyPairData(
        privateBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );
    } else {
      // Генерируем новый keypair
      _identityKeyPair = await _ed25519.newKeyPair();

      final privateBytes = await _identityKeyPair.extractPrivateKeyBytes();
      final publicKey    = await _identityKeyPair.extractPublicKey();

      await _storage.write(key: _keyPrivate, value: base64.encode(privateBytes));
      await _storage.write(key: _keyPublic,  value: base64.encode(publicKey.bytes));
    }

    final pubKey = await _identityKeyPair.extractPublicKey();
    publicKeyHex = _bytesToHex(pubKey.bytes);
  }

  /// Возвращает байты публичного ключа (передаём в BLE advertising)
  Future<Uint8List> getPublicKeyBytes() async {
    final pub = await _identityKeyPair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  // ─── Шифрование сообщений ─────────────────────────────────

  /// Шифрует [plaintext] для получателя с публичным ключом [recipientPublicKeyHex].
  ///
  /// Возвращает [EncryptedMessage] — структуру для передачи по сети.
  Future<EncryptedMessage> encryptMessage({
    required String plaintext,
    required String recipientPublicKeyHex,
  }) async {
    // 1. Эфемерный X25519 keypair для этого сообщения
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    // 2. X25519 ECDH с получателем → общий секрет
    final recipientPublicBytes = _hexToBytes(recipientPublicKeyHex);
    // Ed25519 → X25519 conversion: в реальном продакшне используй
    // libsodium-совместимое преобразование. Здесь используем байты напрямую
    // для простоты прототипа.
    final recipientX25519Key = SimplePublicKey(
      recipientPublicBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientX25519Key,
    );

    // 3. Шифруем ChaCha20-Poly1305
    final nonce = _chacha.newNonce();
    final secretBox = await _chacha.encrypt(
      utf8.encode(plaintext),
      secretKey: sharedSecret,
      nonce: nonce,
    );

    // 4. Подписываем отправителем (authenticity)
    final payload = Uint8List.fromList([
      ...ephemeralPublicKey.bytes,
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    final signature = await _ed25519.sign(payload, keyPair: _identityKeyPair);

    return EncryptedMessage(
      senderPublicKey: publicKeyHex,
      ephemeralPublicKey: _bytesToHex(ephemeralPublicKey.bytes),
      nonce: _bytesToHex(secretBox.nonce),
      cipherText: base64.encode(secretBox.cipherText),
      mac: _bytesToHex(secretBox.mac.bytes),
      signature: _bytesToHex(signature.bytes),
    );
  }

  /// Расшифровывает [message] адресованное нам.
  Future<String?> decryptMessage(EncryptedMessage message) async {
    try {
      // 1. Проверяем подпись отправителя
      final senderPubBytes  = _hexToBytes(message.senderPublicKey);
      final ephemeralBytes  = _hexToBytes(message.ephemeralPublicKey);
      final nonceBytes      = _hexToBytes(message.nonce);
      final cipherBytes     = base64.decode(message.cipherText);
      final macBytes        = _hexToBytes(message.mac);
      final sigBytes        = _hexToBytes(message.signature);

      final payload = Uint8List.fromList([
        ...ephemeralBytes,
        ...nonceBytes,
        ...cipherBytes,
        ...macBytes,
      ]);

      final senderKey = SimplePublicKey(senderPubBytes, type: KeyPairType.ed25519);
      final isValid = await _ed25519.verify(
        payload,
        signature: Signature(sigBytes, publicKey: senderKey),
      );
      if (!isValid) return null;

      // 2. X25519 ECDH: наш приватный ключ + эфемерный публичный
      // Конвертируем наш Ed25519 в X25519 (упрощённо для прототипа)
      final ourPrivateBytes = await _identityKeyPair.extractPrivateKeyBytes();
      final ourX25519KeyPair = SimpleKeyPairData(
        ourPrivateBytes,
        publicKey: SimplePublicKey(
          (await _identityKeyPair.extractPublicKey()).bytes,
          type: KeyPairType.x25519,
        ),
        type: KeyPairType.x25519,
      );

      final ephemeralPublicKey = SimplePublicKey(ephemeralBytes, type: KeyPairType.x25519);
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: ourX25519KeyPair,
        remotePublicKey: ephemeralPublicKey,
      );

      // 3. Расшифровываем
      final secretBox = SecretBox(
        cipherBytes,
        nonce: nonceBytes,
        mac: Mac(macBytes),
      );

      final plainBytes = await _chacha.decrypt(secretBox, secretKey: sharedSecret);
      return utf8.decode(plainBytes);
    } catch (e) {
      return null;
    }
  }

  // ─── Утилиты ─────────────────────────────────────────────

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }
}

/// Зашифрованное сообщение — то, что реально летит по BLE
class EncryptedMessage {
  final String senderPublicKey;     // Ed25519 публичный ключ отправителя (его ID)
  final String ephemeralPublicKey;  // X25519 эфемерный ключ (для ECDH)
  final String nonce;               // 12 байт, hex
  final String cipherText;          // base64
  final String mac;                 // Poly1305 тег, hex
  final String signature;           // Ed25519 подпись, hex

  const EncryptedMessage({
    required this.senderPublicKey,
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
    required this.mac,
    required this.signature,
  });

  factory EncryptedMessage.fromJson(Map<String, dynamic> j) => EncryptedMessage(
        senderPublicKey:    j['spk']  as String,
        ephemeralPublicKey: j['epk']  as String,
        nonce:              j['n']    as String,
        cipherText:         j['ct']   as String,
        mac:                j['mac']  as String,
        signature:          j['sig']  as String,
      );

  Map<String, dynamic> toJson() => {
        'spk':  senderPublicKey,
        'epk':  ephemeralPublicKey,
        'n':    nonce,
        'ct':   cipherText,
        'mac':  mac,
        'sig':  signature,
      };
}
