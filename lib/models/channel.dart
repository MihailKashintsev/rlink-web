import 'dart:convert';

import '../services/channel_directory_relay.dart';
import '../services/gossip_router.dart';
import '../services/image_service.dart';

/// Модель канала. Один админ — создатель, который ведёт канал.
class Channel {
  final String id; // UUID канала
  final String name;
  final String adminId; // publicKeyHex единственного админа
  final List<String> subscriberIds; // подписчики
  final List<String>
      moderatorIds; // модераторы (могут публиковать посты и управлять контентом)
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath;

  /// Баннер «профиля» канала (локальный путь; по сети передаётся отдельным img-потоком).
  final String? bannerImagePath;
  final String? description;
  final bool commentsEnabled; // админ может отключить комментарии
  final int createdAt;
  final bool verified; // канал верифицирован
  final String? verifiedBy; // кто верифицировал: 'auto' или publicKey админа
  final bool foreignAgent; // помечен как ИНОАГЕНТ
  final bool blocked; // заблокирован админом сети
  final String username; // уникальный юзернейм канала (как у пользователей)
  final String
      universalCode; // публичный «универсальный код» канала, пригодный для поиска
  final bool
      isPublic; // true = найдётся в поиске; false = скрытый (only admin-invited)
  /// Резерв истории: шифрованный снимок в сети и опционально в Google Drive (настраивает админ).
  final bool driveBackupEnabled;

  /// Номер последнего опубликованного снимка (для подписчиков — из channel_meta).
  final int driveBackupRev;

  /// Id файла на Google Drive у админа (локально, в gossip не передаётся).
  final String? driveFileId;

  /// Прямая ссылка для скачивания зашифрованного снимка с Google Drive (публичная, только чтение).
  /// Публикуется в channel directory и gossip — подписчики могут восстановить историю без авторизации.
  final String? driveFileUrl;

  /// Публичная ссылка на JSON-файл с ключами подписчиков (каждый завёрнут в X25519).
  /// Позволяет новому устройству получить симметричный ключ без онлайн-рассылки gossip.
  final String? driveKeysUrl;

  /// Разрешить модераторам перепривязывать Google-аккаунт резерва в общих настройках.
  final bool allowModeratorsManageDriveAccount;

  /// Админы «ссылок» — могут публиковать наравне с модераторами (роль для делегирования).
  final List<String> linkAdminIds;

  /// Показывать подпись к посту для перечисленных в [staffLabels] авторов.
  final bool signStaffPosts;

  /// Подпись по публичному ключу автора поста (если включено).
  final Map<String, String> staffLabels;

  const Channel({
    required this.id,
    required this.name,
    required this.adminId,
    required this.subscriberIds,
    this.moderatorIds = const [],
    this.linkAdminIds = const [],
    this.signStaffPosts = false,
    this.staffLabels = const {},
    this.avatarColor = 0xFF42A5F5,
    this.avatarEmoji = '📢',
    this.avatarImagePath,
    this.bannerImagePath,
    this.description,
    this.commentsEnabled = true,
    required this.createdAt,
    this.verified = false,
    this.verifiedBy,
    this.foreignAgent = false,
    this.blocked = false,
    this.username = '',
    this.universalCode = '',
    this.isPublic = true,
    this.driveBackupEnabled = false,
    this.driveBackupRev = 0,
    this.driveFileId,
    this.driveFileUrl,
    this.driveKeysUrl,
    this.allowModeratorsManageDriveAccount = false,
  });

  bool get isAdmin => false; // checked externally via adminId

  /// Админ, модератор или админ ссылок.
  bool canPost(String userId) =>
      userId == adminId ||
      moderatorIds.contains(userId) ||
      linkAdminIds.contains(userId);

  /// Подпись для нового поста (если включено и для ключа задана непустая строка).
  String? staffLabelForNewPost(String authorId) {
    if (!signStaffPosts) return null;
    if (!canPost(authorId)) return null;
    final s = staffLabels[authorId];
    if (s == null || s.trim().isEmpty) return null;
    return s.trim();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'admin': adminId,
        'subs': subscriberIds,
        if (moderatorIds.isNotEmpty) 'mods': moderatorIds,
        if (linkAdminIds.isNotEmpty) 'links': linkAdminIds,
        if (signStaffPosts) 'signStaff': true,
        if (staffLabels.isNotEmpty) 'slb': staffLabels,
        'color': avatarColor,
        'emoji': avatarEmoji,
        if (avatarImagePath != null) 'img': avatarImagePath,
        if (bannerImagePath != null) 'bn': bannerImagePath,
        if (description != null) 'desc': description,
        'comments': commentsEnabled,
        'ts': createdAt,
        'verified': verified,
        if (verifiedBy != null) 'verifiedBy': verifiedBy,
        if (foreignAgent) 'foreignAgent': true,
        if (blocked) 'blocked': true,
        if (username.isNotEmpty) 'u': username,
        if (universalCode.isNotEmpty) 'uc': universalCode,
        'pub': isPublic,
        if (driveBackupEnabled) 'drv': true,
        if (driveBackupRev > 0) 'drvRev': driveBackupRev,
        if (driveFileUrl != null && driveFileUrl!.isNotEmpty) 'drvUrl': driveFileUrl,
        if (driveKeysUrl != null && driveKeysUrl!.isNotEmpty) 'drvKUrl': driveKeysUrl,
        if (allowModeratorsManageDriveAccount) 'drvMods': true,
      };

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['id'] as String,
        name: j['name'] as String,
        adminId: j['admin'] as String,
        subscriberIds: (j['subs'] as List).cast<String>(),
        moderatorIds:
            j['mods'] != null ? (j['mods'] as List).cast<String>() : const [],
        linkAdminIds:
            j['links'] != null ? (j['links'] as List).cast<String>() : const [],
        signStaffPosts: j['signStaff'] == true,
        staffLabels: j['slb'] is Map
            ? (j['slb'] as Map).map(
                (k, v) => MapEntry(k.toString(), v.toString()),
              )
            : const {},
        avatarColor: j['color'] as int? ?? 0xFF42A5F5,
        avatarEmoji: j['emoji'] as String? ?? '📢',
        avatarImagePath: j['img'] as String?,
        bannerImagePath: j['bn'] as String?,
        description: j['desc'] as String?,
        commentsEnabled: j['comments'] as bool? ?? true,
        createdAt: j['ts'] as int? ?? 0,
        verified: j['verified'] as bool? ?? false,
        verifiedBy: j['verifiedBy'] as String?,
        foreignAgent: j['foreignAgent'] as bool? ?? false,
        blocked: j['blocked'] as bool? ?? false,
        username: j['u'] as String? ?? '',
        universalCode: j['uc'] as String? ?? '',
        isPublic: j['pub'] as bool? ?? true,
        driveBackupEnabled: j['drv'] == true,
        driveBackupRev: (j['drvRev'] as num?)?.toInt() ?? 0,
        driveFileId: j['drvFid'] as String?,
        driveFileUrl: j['drvUrl'] as String?,
        driveKeysUrl: j['drvKUrl'] as String?,
        allowModeratorsManageDriveAccount: j['drvMods'] == true,
      );

  String encode() => jsonEncode(toJson());

  static Channel? tryDecode(String s) {
    try {
      return Channel.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Channel copyWith({
    String? adminId,
    String? name,
    List<String>? subscriberIds,
    List<String>? moderatorIds,
    List<String>? linkAdminIds,
    bool? signStaffPosts,
    Map<String, String>? staffLabels,
    int? avatarColor,
    String? avatarEmoji,
    String? avatarImagePath,
    String? bannerImagePath,
    String? description,
    bool? commentsEnabled,
    bool? verified,
    String? verifiedBy,
    bool? foreignAgent,
    bool? blocked,
    String? username,
    String? universalCode,
    bool? isPublic,
    bool? driveBackupEnabled,
    int? driveBackupRev,
    String? driveFileId,
    String? driveFileUrl,
    String? driveKeysUrl,
    bool? allowModeratorsManageDriveAccount,
  }) =>
      Channel(
        id: id,
        name: name ?? this.name,
        adminId: adminId ?? this.adminId,
        subscriberIds: subscriberIds ?? this.subscriberIds,
        moderatorIds: moderatorIds ?? this.moderatorIds,
        linkAdminIds: linkAdminIds ?? this.linkAdminIds,
        signStaffPosts: signStaffPosts ?? this.signStaffPosts,
        staffLabels: staffLabels ?? this.staffLabels,
        avatarColor: avatarColor ?? this.avatarColor,
        avatarEmoji: avatarEmoji ?? this.avatarEmoji,
        avatarImagePath: avatarImagePath ?? this.avatarImagePath,
        bannerImagePath: bannerImagePath ?? this.bannerImagePath,
        description: description ?? this.description,
        commentsEnabled: commentsEnabled ?? this.commentsEnabled,
        createdAt: createdAt,
        verified: verified ?? this.verified,
        verifiedBy: verifiedBy ?? this.verifiedBy,
        foreignAgent: foreignAgent ?? this.foreignAgent,
        blocked: blocked ?? this.blocked,
        username: username ?? this.username,
        universalCode: universalCode ?? this.universalCode,
        isPublic: isPublic ?? this.isPublic,
        driveBackupEnabled: driveBackupEnabled ?? this.driveBackupEnabled,
        driveBackupRev: driveBackupRev ?? this.driveBackupRev,
        driveFileId: driveFileId ?? this.driveFileId,
        driveFileUrl: driveFileUrl ?? this.driveFileUrl,
        driveKeysUrl: driveKeysUrl ?? this.driveKeysUrl,
        allowModeratorsManageDriveAccount: allowModeratorsManageDriveAccount ??
            this.allowModeratorsManageDriveAccount,
      );
}

/// Пост в канале.
class ChannelPost {
  final String id;
  final String channelId;
  final String authorId;
  final String text;
  final String? imagePath;
  final String? videoPath;
  final String? voicePath;
  final String? filePath;
  final String? fileName;
  final int? fileSize;
  final int timestamp;
  final List<ChannelComment> comments;
  final Map<String, List<String>> reactions;
  final String? pollJson;

  /// Уникальные просмотры (по публичному ключу зрителя), синхронизируются через gossip.
  final int viewCount;

  /// Локальный счётчик пересылок поста из канала.
  final int forwardCount;

  /// Подпись автора (при включённой опции канала).
  final String? staffLabel;

  /// Стикер (компактное отображение; по сети флаг `stk` + файл `stk_*.jpg`).
  final bool isSticker;

  const ChannelPost({
    required this.id,
    required this.channelId,
    required this.authorId,
    this.text = '',
    this.imagePath,
    this.videoPath,
    this.voicePath,
    this.filePath,
    this.fileName,
    this.fileSize,
    required this.timestamp,
    this.comments = const [],
    this.reactions = const {},
    this.pollJson,
    this.viewCount = 0,
    this.forwardCount = 0,
    this.staffLabel,
    this.isSticker = false,
  });

  int get totalReactions {
    var n = 0;
    for (final list in reactions.values) {
      n += list.length;
    }
    return n;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'channel_id': channelId,
        'author_id': authorId,
        'text': text,
        'image_path': imagePath,
        'video_path': videoPath,
        'voice_path': voicePath,
        'file_path': filePath,
        'file_name': fileName,
        'file_size': fileSize,
        'timestamp': timestamp,
        'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
        'poll_json': pollJson,
        'view_count': viewCount,
        'forward_count': forwardCount,
        'staff_label': staffLabel,
        'is_sticker': isSticker ? 1 : 0,
      };

  ChannelPost copyWith({
    String? text,
    String? imagePath,
    String? videoPath,
    String? voicePath,
    String? filePath,
    String? fileName,
    int? fileSize,
    int? timestamp,
    List<ChannelComment>? comments,
    Map<String, List<String>>? reactions,
    String? pollJson,
    int? viewCount,
    int? forwardCount,
    String? staffLabel,
    bool? isSticker,
  }) =>
      ChannelPost(
        id: id,
        channelId: channelId,
        authorId: authorId,
        text: text ?? this.text,
        imagePath: imagePath ?? this.imagePath,
        videoPath: videoPath ?? this.videoPath,
        voicePath: voicePath ?? this.voicePath,
        filePath: filePath ?? this.filePath,
        fileName: fileName ?? this.fileName,
        fileSize: fileSize ?? this.fileSize,
        timestamp: timestamp ?? this.timestamp,
        comments: comments ?? this.comments,
        reactions: reactions ?? this.reactions,
        pollJson: pollJson ?? this.pollJson,
        viewCount: viewCount ?? this.viewCount,
        forwardCount: forwardCount ?? this.forwardCount,
        staffLabel: staffLabel ?? this.staffLabel,
        isSticker: isSticker ?? this.isSticker,
      );

  factory ChannelPost.fromMap(Map<String, dynamic> m,
      {List<ChannelComment> comments = const []}) {
    Map<String, List<String>> reactions = const {};
    final raw = m['reactions'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        reactions =
            decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
      } catch (_) {}
    }
    final resolve = ImageService.instance.resolveStoredPath;
    return ChannelPost(
      id: m['id'] as String,
      channelId: m['channel_id'] as String,
      authorId: m['author_id'] as String,
      text: m['text'] as String? ?? '',
      imagePath: resolve(m['image_path'] as String?),
      videoPath: resolve(m['video_path'] as String?),
      voicePath: resolve(m['voice_path'] as String?),
      filePath: resolve(m['file_path'] as String?),
      fileName: m['file_name'] as String?,
      fileSize: m['file_size'] as int?,
      timestamp: m['timestamp'] as int,
      comments: comments,
      reactions: reactions,
      pollJson: m['poll_json'] as String?,
      viewCount: (m['view_count'] as int?) ?? 0,
      forwardCount: (m['forward_count'] as int?) ?? 0,
      staffLabel: m['staff_label'] as String?,
      isSticker: (m['is_sticker'] as int?) == 1,
    );
  }
}

/// Комментарий к посту.
class ChannelComment {
  final String id;
  final String postId;
  final String authorId;
  final String text;
  final String? imagePath;
  final String? videoPath;
  final String? voicePath;
  final String? filePath;
  final String? fileName;
  final int? fileSize;
  final int timestamp;
  final Map<String, List<String>> reactions;

  const ChannelComment({
    required this.id,
    required this.postId,
    required this.authorId,
    required this.text,
    this.imagePath,
    this.videoPath,
    this.voicePath,
    this.filePath,
    this.fileName,
    this.fileSize,
    required this.timestamp,
    this.reactions = const {},
  });

  int get totalReactions {
    var n = 0;
    for (final list in reactions.values) {
      n += list.length;
    }
    return n;
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'post_id': postId,
        'author_id': authorId,
        'text': text,
        'image_path': imagePath,
        'video_path': videoPath,
        'voice_path': voicePath,
        'file_path': filePath,
        'file_name': fileName,
        'file_size': fileSize,
        'timestamp': timestamp,
        'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
      };

  factory ChannelComment.fromMap(Map<String, dynamic> m) {
    Map<String, List<String>> reactions = const {};
    final raw = m['reactions'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        reactions =
            decoded.map((k, v) => MapEntry(k, (v as List).cast<String>()));
      } catch (_) {}
    }
    final resolve = ImageService.instance.resolveStoredPath;
    return ChannelComment(
      id: m['id'] as String,
      postId: m['post_id'] as String,
      authorId: m['author_id'] as String,
      text: m['text'] as String? ?? '',
      imagePath: resolve(m['image_path'] as String?),
      videoPath: resolve(m['video_path'] as String?),
      voicePath: resolve(m['voice_path'] as String?),
      filePath: resolve(m['file_path'] as String?),
      fileName: m['file_name'] as String?,
      fileSize: m['file_size'] as int?,
      timestamp: m['timestamp'] as int,
      reactions: reactions,
    );
  }
}

extension ChannelGossipBroadcast on Channel {
  /// Полный `channel_meta` для текущего состояния канала (публичные — в эфир)
  /// и снимок на relay для обнаружения без онлайн-админа.
  Future<void> broadcastGossipMeta() async {
    await GossipRouter.instance.broadcastChannelMeta(
      channelId: id,
      name: name,
      adminId: adminId,
      avatarColor: avatarColor,
      avatarEmoji: avatarEmoji,
      description: description,
      commentsEnabled: commentsEnabled,
      createdAt: createdAt,
      verified: verified,
      verifiedBy: verifiedBy,
      subscriberIds: subscriberIds,
      moderatorIds: moderatorIds,
      linkAdminIds: linkAdminIds,
      signStaffPosts: signStaffPosts,
      staffLabels: staffLabels,
      username: username,
      universalCode: universalCode,
      isPublic: isPublic,
      driveBackup: driveBackupEnabled,
      driveBackupRev: driveBackupRev,
      allowModeratorsManageDriveAccount: allowModeratorsManageDriveAccount,
    );
    await ChannelDirectoryRelay.publishIfAdmin(this);
  }
}
