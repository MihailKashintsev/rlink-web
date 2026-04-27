import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import 'ai_bot_constants.dart';
import 'chat_storage_service.dart';

/// Интеграция с [GigaChat](https://developers.sber.ru/docs/ru/gigachat) (Сбер).
/// Ключ: Authorization Key из личного кабинета (Base64 от `client_id:client_secret`).
class GigachatService {
  GigachatService._();
  static final GigachatService instance = GigachatService._();

  static const _kAuthKey = 'gigachat_authorization_key';
  /// Опционально: не проверять цепочку TLS только для узлов GigaChat (см. профиль).
  static const _kInsecureTlsWorkaround = 'gigachat_insecure_tls_sber_hosts';
  static const _oauthUrl =
      'https://ngw.devices.sberbank.ru:9443/api/v2/oauth';
  static const _chatUrl =
      'https://gigachat.devices.sberbank.ru/api/v1/chat/completions';
  static const _filesUrl =
      'https://gigachat.devices.sberbank.ru/api/v1/files';

  static bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 45),
    receiveTimeout: const Duration(seconds: 120),
    validateStatus: (s) => s != null && s < 500,
  ));

  bool _dioAdapterSynced = false;
  bool _dioAdapterInsecure = false;

  static bool _allowBadCertForGigaChatHosts(
    X509Certificate cert,
    String host,
    int port,
  ) {
    return host == 'ngw.devices.sberbank.ru' ||
        host == 'gigachat.devices.sberbank.ru' ||
        host.endsWith('.devices.sberbank.ru');
  }

  /// Обход проверки HTTPS только для официальных хостов API GigaChat (опасно при MITM).
  Future<bool> readInsecureTlsWorkaroundEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kInsecureTlsWorkaround) ?? false;
  }

  Future<void> setInsecureTlsWorkaroundEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kInsecureTlsWorkaround, enabled);
    _dioAdapterSynced = false;
    _accessToken = null;
    _tokenExpiresAtSec = null;
    await _syncDioAdapter();
  }

  Future<void> _syncDioAdapter() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    final insecure = prefs.getBool(_kInsecureTlsWorkaround) ?? false;
    if (_dioAdapterSynced && insecure == _dioAdapterInsecure) return;
    _dioAdapterInsecure = insecure;
    _dioAdapterSynced = true;
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        if (insecure) {
          client.badCertificateCallback = _allowBadCertForGigaChatHosts;
        }
        return client;
      },
    );
  }

  static bool _looksLikeCertFailure(Object? err, String? message) {
    final blob = '${err ?? ''} ${message ?? ''}'.toUpperCase();
    return blob.contains('CERTIFICATE') ||
        blob.contains('HANDSHAKE') ||
        blob.contains('TLSV1') ||
        blob.contains('SSLV3');
  }

  /// Понятное сообщение при сбое проверки HTTPS (часто VPN, антивирус, Charles, неверное время).
  static String _certFailureHint() {
    return 'Не удалось проверить сертификат сервера GigaChat (HTTPS). '
        'Проверьте дату и время на устройстве. Отключите VPN, антивирус с проверкой HTTPS '
        'и отладочные прокси (Charles, Fiddler). В корпоративной сети попробуйте мобильный интернет '
        'или сеть без подмены сертификатов. '
        'Как крайний вариант: Профиль → ИИ (GigaChat) → «Обход проверки сертификата» '
        '(только узлы Сбера; снижает защиту от перехвата).';
  }

  static GigachatException _fromDioException(DioException e, String context) {
    if (e.type == DioExceptionType.badCertificate ||
        _looksLikeCertFailure(e.error, e.message)) {
      return GigachatException('$context: ${_certFailureHint()}');
    }
    final underlying = e.error?.toString();
    final msg = e.message;
    final combined = [
      if (msg != null && msg.isNotEmpty) msg,
      if (underlying != null &&
          underlying.isNotEmpty &&
          underlying != msg)
        underlying,
    ].join(' — ');
    return GigachatException(
      '$context: ${combined.isEmpty ? e.type.name : combined}',
    );
  }

  String? _accessToken;
  int? _tokenExpiresAtSec;

  Future<String?> readAuthorizationKey() async {
    if (_isMobile) return _secure.read(key: _kAuthKey);
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kAuthKey);
  }

  Future<void> saveAuthorizationKey(String? value) async {
    _accessToken = null;
    _tokenExpiresAtSec = null;
    if (value == null || value.trim().isEmpty) {
      if (_isMobile) {
        await _secure.delete(key: _kAuthKey);
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_kAuthKey);
      }
      return;
    }
    final v = value.trim();
    if (_isMobile) {
      await _secure.write(key: _kAuthKey, value: v);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAuthKey, v);
    }
  }

  Future<void> clear() async {
    _accessToken = null;
    _tokenExpiresAtSec = null;
    if (_isMobile) {
      await _secure.delete(key: _kAuthKey);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kAuthKey);
    }
  }

  Future<bool> get hasAuthorizationKey async {
    final k = await readAuthorizationKey();
    return k != null && k.trim().isNotEmpty;
  }

  String _normalizeAuthHeader(String raw) {
    final t = raw.trim();
    if (t.toLowerCase().startsWith('basic ')) return t;
    return 'Basic $t';
  }

  Future<String> _ensureAccessToken(String authorizationKey) async {
    await _syncDioAdapter();
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_accessToken != null &&
        _tokenExpiresAtSec != null &&
        nowSec < _tokenExpiresAtSec! - 60) {
      return _accessToken!;
    }

    final rqUid = const Uuid().v4();
    final Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        _oauthUrl,
        options: Options(
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
            'RqUID': rqUid,
            'Authorization': _normalizeAuthHeader(authorizationKey),
          },
        ),
        data: 'scope=GIGACHAT_API_PERS',
      );
    } on DioException catch (e) {
      throw _fromDioException(e, 'OAuth GigaChat');
    }

    if (resp.statusCode != 200 || resp.data is! Map) {
      throw GigachatException(
        'OAuth ${resp.statusCode}: ${_shortErr(resp.data)}',
      );
    }
    final map = resp.data as Map<String, dynamic>;
    final token = map['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw GigachatException('Нет access_token в ответе OAuth');
    }
    final exp = (map['expires_at'] as num?)?.toInt();
    _accessToken = token;
    _tokenExpiresAtSec = exp;
    return token;
  }

  /// Загрузка файла в хранилище GigaChat; возвращает `id` для поля `attachments`.
  Future<String> uploadFile(String filePath) async {
    final auth = await readAuthorizationKey();
    if (auth == null || auth.trim().isEmpty) {
      throw GigachatException(
        'Не указан ключ GigaChat. Откройте Профиль → блок «ИИ (GigaChat)».',
      );
    }
    final token = await _ensureAccessToken(auth);
    final name = p.basename(filePath);
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: name),
      'purpose': 'general',
    });
    final Response<dynamic> resp;
    try {
      resp = await _dio.post<dynamic>(
        _filesUrl,
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
        data: form,
      );
    } on DioException catch (e) {
      throw _fromDioException(e, 'Загрузка файла GigaChat');
    }
    if (resp.statusCode != 200 || resp.data is! Map) {
      throw GigachatException(
        'Upload ${resp.statusCode}: ${_shortErr(resp.data)}',
      );
    }
    final id = (resp.data as Map)['id'] as String?;
    if (id == null || id.isEmpty) {
      throw GigachatException('Нет id файла в ответе загрузки');
    }
    return id;
  }

  static String _apiUserContent(ChatMessage m) {
    final t = m.text.trim();
    final hasAtt = m.gigachatAttachmentIds.isNotEmpty;
    if (!hasAtt) return t.isEmpty ? ' ' : t;
    final placeholderOnly = t.isEmpty ||
        t == '📷' ||
        (t.startsWith('📎') && t.length <= 80 && !t.contains('?'));
    if (placeholderOnly) {
      return 'Опиши вложение и ответь по существу.';
    }
    return t;
  }

  /// История из локального чата с ботом → сообщения для API.
  Future<List<Map<String, dynamic>>> _historyFromDb({int maxMessages = 24}) async {
    final msgs =
        await ChatStorageService.instance.getRecentMessagesAscending(
      kGigachatBotPeerId,
      limit: maxMessages,
    );
    final usable = msgs.where((m) {
      if (m.text.trim().isNotEmpty) return true;
      if (m.isOutgoing && m.gigachatAttachmentIds.isNotEmpty) return true;
      return false;
    }).toList();
    final slice = usable.length > maxMessages
        ? usable.sublist(usable.length - maxMessages)
        : usable;
    final out = <Map<String, dynamic>>[];
    for (final m in slice) {
      final entry = <String, dynamic>{
        'role': m.isOutgoing ? 'user' : 'assistant',
        'content': m.isOutgoing ? _apiUserContent(m) : m.text.trim(),
      };
      if (m.isOutgoing && m.gigachatAttachmentIds.isNotEmpty) {
        entry['attachments'] = List<String>.from(m.gigachatAttachmentIds);
      }
      out.add(entry);
    }
    return out;
  }

  static String? _normalizeAssistantContent(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      final s = raw.trim();
      return s.isEmpty ? null : s;
    }
    if (raw is List) {
      final buf = StringBuffer();
      for (final item in raw) {
        if (item is Map) {
          if (item['type'] == 'text' && item['text'] is String) {
            buf.write(item['text'] as String);
          }
        }
      }
      final s = buf.toString().trim();
      return s.isEmpty ? null : s;
    }
    return null;
  }

  /// Запрос ответа модели. Последнее сообщение пользователя уже должно быть в БД.
  Future<String> completeAfterUserMessage() async {
    final auth = await readAuthorizationKey();
    if (auth == null || auth.trim().isEmpty) {
      throw GigachatException(
        'Не указан ключ GigaChat. Откройте Профиль → блок «ИИ (GigaChat)».',
      );
    }

    final token = await _ensureAccessToken(auth);
    final history = await _historyFromDb();
    if (history.isEmpty || history.last['role'] != 'user') {
      throw GigachatException(
        'Нет сообщения пользователя для ответа. Отправьте текст ещё раз.',
      );
    }

    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content':
            'Ты дружелюбный ассистент в мессенджере Rlink. Отвечай по существу, '
            'на том же языке, что и пользователь. Не выдумывай факты о людях и устройствах в сети.',
      },
      ...history,
    ];

    const modelCandidates = <String>[
      'GigaChat',
      'GigaChat-Pro',
      'GigaChat-2',
    ];

    Response<dynamic>? resp;
    Object? lastErr;
    for (final model in modelCandidates) {
      try {
        final r = await _dio.post<dynamic>(
          _chatUrl,
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': 'Bearer $token',
            },
          ),
          data: {
            'model': model,
            'messages': messages,
            'max_tokens': 1024,
            'temperature': 0.7,
          },
        );
        if (r.statusCode == 200 && r.data is Map) {
          resp = r;
          break;
        }
        lastErr = 'HTTP ${r.statusCode}: ${_shortErr(r.data)}';
      } on DioException catch (e) {
        lastErr = _fromDioException(e, 'Запрос GigaChat');
      } catch (e) {
        lastErr = e;
      }
    }

    if (resp == null || resp.data is! Map) {
      if (lastErr is GigachatException) throw lastErr;
      throw GigachatException(
        'GigaChat: ${lastErr ?? "не удалось получить ответ"}',
      );
    }
    final map = resp.data as Map<String, dynamic>;
    final choices = map['choices'];
    if (choices is! List || choices.isEmpty) {
      throw GigachatException('Пустой ответ модели');
    }
    final firstChoice = choices.first as Map;
    final msg = firstChoice['message'];
    if (msg is! Map) {
      throw GigachatException('Некорректный формат ответа');
    }
    final parsed = _normalizeAssistantContent(msg['content']);
    if (parsed != null && parsed.isNotEmpty) {
      return parsed;
    }
    final finish = firstChoice['finish_reason']?.toString() ?? '';
    final fn = msg['function_call'];
    if (fn != null) {
      throw GigachatException(
        'Модель запросила вызов функции вместо текста ($fn). '
        'Попробуйте переформулировать вопрос.',
      );
    }
    throw GigachatException(
      'Модель вернула пустой текст${finish.isNotEmpty ? ' (finish: $finish)' : ''}',
    );
  }

  String _shortErr(dynamic data) {
    try {
      if (data is Map) {
        return jsonEncode(data).length > 280
            ? '${jsonEncode(data).substring(0, 280)}…'
            : jsonEncode(data);
      }
      return data.toString();
    } catch (_) {
      return 'ошибка';
    }
  }
}

class GigachatException implements Exception {
  final String message;
  GigachatException(this.message);

  @override
  String toString() => message;
}
