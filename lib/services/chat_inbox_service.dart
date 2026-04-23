import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'group_service.dart';

/// Вид элемента в списке чатов (для фильтров).
enum ChatInboxItemKind { saved, dm, group, channel }

/// Вкладка фильтра: пресет или пользовательская группа.
class ChatInboxTab {
  final String id;
  /// all | dm | channel | group для встроенных; null = custom
  final String? preset;
  final String customName;
  final List<String> customMemberKeys;

  const ChatInboxTab({
    required this.id,
    this.preset,
    this.customName = '',
    this.customMemberKeys = const [],
  });

  bool matches(String itemKey, ChatInboxItemKind kind) {
    switch (preset) {
      case 'all':
        return true;
      case 'dm':
        return kind == ChatInboxItemKind.dm || kind == ChatInboxItemKind.saved;
      case 'channel':
        return kind == ChatInboxItemKind.channel;
      case 'group':
        return kind == ChatInboxItemKind.group;
      default:
        return customMemberKeys.contains(itemKey);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (preset != null) 'preset': preset,
        if (customName.isNotEmpty) 'name': customName,
        if (customMemberKeys.isNotEmpty) 'keys': customMemberKeys,
      };

  static ChatInboxTab fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String? ?? '';
    final preset = j['preset'] as String?;
    final name = j['name'] as String? ?? '';
    final keys = (j['keys'] as List<dynamic>?)?.cast<String>() ?? const [];
    return ChatInboxTab(
      id: id,
      preset: preset,
      customName: name,
      customMemberKeys: keys,
    );
  }
}

/// Закреплённые, архив, вкладки фильтров для главного списка чатов.
class ChatInboxService extends ChangeNotifier {
  ChatInboxService._();
  static final ChatInboxService instance = ChatInboxService._();

  static const _kTabs = 'chat_inbox_tabs_v1';
  static const _kSelected = 'chat_inbox_selected_v1';
  static const _kPins = 'chat_inbox_pins_v1';
  static const _kArchived = 'chat_inbox_archived_v1';
  static const _kArchiveView = 'chat_inbox_archive_view_v1';

  static const idAll = '__all__';
  static const idDm = '__dm__';
  static const idChannel = '__channel__';
  static const idGroup = '__group__';

  final _uuid = const Uuid();
  SharedPreferences? _prefs;
  List<ChatInboxTab> _tabs = [];
  String _selectedTabId = idAll;
  List<String> _pinOrder = [];
  Set<String> _archived = {};
  bool _archiveView = false;

  List<ChatInboxTab> get tabs => List.unmodifiable(_tabs);
  String get selectedTabId => _selectedTabId;
  List<String> get pinOrder => List.unmodifiable(_pinOrder);
  Set<String> get archived => Set.unmodifiable(_archived);
  bool get archiveView => _archiveView;

  ChatInboxTab? get selectedTab {
    for (final t in _tabs) {
      if (t.id == _selectedTabId) return t;
    }
    return _tabs.isEmpty ? null : _tabs.first;
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _load();
  }

  void _load() {
    final p = _prefs;
    if (p == null) return;

    final rawTabs = p.getString(_kTabs);
    if (rawTabs != null && rawTabs.isNotEmpty) {
      try {
        final list = jsonDecode(rawTabs) as List<dynamic>;
        _tabs = list
            .map((e) => ChatInboxTab.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        _tabs = _defaultTabs();
      }
    } else {
      _tabs = _defaultTabs();
    }

    if (_tabs.isEmpty) {
      _tabs = _defaultTabs();
    }

    _selectedTabId = p.getString(_kSelected) ?? idAll;
    if (!_tabs.any((t) => t.id == _selectedTabId)) {
      _selectedTabId = _tabs.first.id;
    }

    final rawPins = p.getString(_kPins);
    if (rawPins != null && rawPins.isNotEmpty) {
      try {
        final list = jsonDecode(rawPins) as List<dynamic>;
        _pinOrder = list.cast<String>();
      } catch (_) {
        _pinOrder = [];
      }
    } else {
      _pinOrder = [];
    }

    final rawArc = p.getString(_kArchived);
    if (rawArc != null && rawArc.isNotEmpty) {
      try {
        final list = jsonDecode(rawArc) as List<dynamic>;
        _archived = list.cast<String>().toSet();
      } catch (_) {
        _archived = {};
      }
    } else {
      _archived = {};
    }

    _archiveView = p.getBool(_kArchiveView) ?? false;
  }

  List<ChatInboxTab> _defaultTabs() => const [
        ChatInboxTab(id: idAll, preset: 'all'),
        ChatInboxTab(id: idDm, preset: 'dm'),
        ChatInboxTab(id: idChannel, preset: 'channel'),
        ChatInboxTab(id: idGroup, preset: 'group'),
      ];

  Future<void> _persistTabs() async {
    final p = _prefs;
    if (p == null) return;
    final enc = jsonEncode(_tabs.map((t) => t.toJson()).toList());
    await p.setString(_kTabs, enc);
  }

  Future<void> _persistPins() async {
    final p = _prefs;
    if (p == null) return;
    await p.setString(_kPins, jsonEncode(_pinOrder));
  }

  Future<void> _persistArchived() async {
    final p = _prefs;
    if (p == null) return;
    await p.setString(_kArchived, jsonEncode(_archived.toList()));
  }

  Future<void> setSelectedTab(String id) async {
    if (!_tabs.any((t) => t.id == id)) return;
    _selectedTabId = id;
    _archiveView = false;
    await _prefs?.setString(_kSelected, _selectedTabId);
    await _prefs?.setBool(_kArchiveView, false);
    notifyListeners();
  }

  Future<void> setArchiveView(bool v) async {
    _archiveView = v;
    await _prefs?.setBool(_kArchiveView, v);
    notifyListeners();
  }

  Future<void> reorderTabs(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final item = _tabs.removeAt(oldIndex);
    _tabs.insert(newIndex, item);
    await _persistTabs();
    notifyListeners();
  }

  Future<void> removeTab(String id) async {
    _tabs.removeWhere((t) => t.id == id);
    if (_tabs.isEmpty) {
      _tabs = _defaultTabs();
    }
    if (_selectedTabId == id) {
      _selectedTabId = _tabs.first.id;
      await _prefs?.setString(_kSelected, _selectedTabId);
    }
    await _persistTabs();
    notifyListeners();
  }

  Future<void> addCustomTab(String name, List<String> memberKeys) async {
    final id = 'c_${_uuid.v4()}';
    _tabs.add(ChatInboxTab(
      id: id,
      preset: null,
      customName: name.trim().isEmpty ? 'Группа' : name.trim(),
      customMemberKeys: List<String>.from(memberKeys),
    ));
    _selectedTabId = id;
    await _prefs?.setString(_kSelected, _selectedTabId);
    await _persistTabs();
    notifyListeners();
  }

  Future<void> resetDefaultTabs() async {
    _tabs = _defaultTabs();
    _selectedTabId = idAll;
    await _prefs?.setString(_kSelected, _selectedTabId);
    await _persistTabs();
    notifyListeners();
  }

  bool isPinned(String key) => _pinOrder.contains(key);

  Future<void> pin(String key) async {
    if (_archived.contains(key)) return;
    if (_pinOrder.contains(key)) return;
    _pinOrder.add(key);
    await _persistPins();
    notifyListeners();
  }

  Future<void> unpin(String key) async {
    _pinOrder.remove(key);
    await _persistPins();
    notifyListeners();
  }

  Future<void> setPinOrder(List<String> keys) async {
    _pinOrder = List<String>.from(keys);
    await _persistPins();
    notifyListeners();
  }

  bool isArchived(String key) => _archived.contains(key);

  Future<void> archive(String key) async {
    _archived.add(key);
    _pinOrder.remove(key);
    await _persistArchived();
    await _persistPins();
    notifyListeners();
  }

  Future<void> unarchive(String key) async {
    _archived.remove(key);
    await _persistArchived();
    notifyListeners();
  }

  /// Подпись вкладки для UI.
  String tabLabel(ChatInboxTab t) {
    switch (t.preset) {
      case 'all':
        return 'Все';
      case 'dm':
        return 'Чаты';
      case 'channel':
        return 'Каналы';
      case 'group':
        return 'Группы';
      default:
        return t.customName.isEmpty ? 'Группа' : t.customName;
    }
  }
}

/// Строка для экрана выбора чатов в пользовательскую группу.
class ChatInboxPickRow {
  final String storageKey;
  final String title;
  final ChatInboxItemKind kind;

  const ChatInboxPickRow({
    required this.storageKey,
    required this.title,
    required this.kind,
  });

  IconData get icon => switch (kind) {
        ChatInboxItemKind.dm => Icons.person_outline,
        ChatInboxItemKind.group => Icons.group_outlined,
        ChatInboxItemKind.channel => Icons.campaign_outlined,
        ChatInboxItemKind.saved => Icons.bookmark_outline,
      };
}

/// Загрузка всех доступных диалогов для множественного выбора.
Future<List<ChatInboxPickRow>> loadChatInboxPickRows() async {
  final rows = <ChatInboxPickRow>[];
  final myId = CryptoService.instance.publicKeyHex;
  final seen = <String>{};

  final summaries = await ChatStorageService.instance.getChatSummaries();
  for (final s in summaries) {
    if (myId.isNotEmpty && s.peerId == myId) continue;
    final k = chatInboxKey(kind: ChatInboxItemKind.dm, id: s.peerId);
    if (seen.add(k)) {
      rows.add(ChatInboxPickRow(
        storageKey: k,
        title: s.nickname ??
            '${s.peerId.substring(0, s.peerId.length.clamp(0, 8))}...',
        kind: ChatInboxItemKind.dm,
      ));
    }
  }
  final contacts = await ChatStorageService.instance.getContacts();
  for (final c in contacts) {
    if (myId.isNotEmpty && c.publicKeyHex == myId) continue;
    final k = chatInboxKey(kind: ChatInboxItemKind.dm, id: c.publicKeyHex);
    if (seen.add(k)) {
      rows.add(ChatInboxPickRow(
        storageKey: k,
        title: c.nickname.isNotEmpty
            ? c.nickname
            : '${c.publicKeyHex.substring(0, 8)}...',
        kind: ChatInboxItemKind.dm,
      ));
    }
  }

  final groups = await GroupService.instance.getGroups();
  for (final g in groups) {
    if (g.creatorId != myId && !g.memberIds.contains(myId)) continue;
    final k = chatInboxKey(kind: ChatInboxItemKind.group, id: g.id);
    if (seen.add(k)) {
      rows.add(ChatInboxPickRow(
        storageKey: k,
        title: g.name,
        kind: ChatInboxItemKind.group,
      ));
    }
  }

  final channels = await ChannelService.instance.getChannels();
  for (final ch in channels) {
    if (myId.isEmpty) continue;
    if (ch.adminId != myId &&
        !ch.subscriberIds.contains(myId) &&
        !ch.moderatorIds.contains(myId) &&
        !ch.linkAdminIds.contains(myId)) {
      continue;
    }
    final k = chatInboxKey(kind: ChatInboxItemKind.channel, id: ch.id);
    if (seen.add(k)) {
      rows.add(ChatInboxPickRow(
        storageKey: k,
        title: ch.name,
        kind: ChatInboxItemKind.channel,
      ));
    }
  }

  rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return rows;
}

/// Ключ для хранения (совпадает с логикой списка).
String chatInboxKey({
  required ChatInboxItemKind kind,
  required String id,
}) {
  switch (kind) {
    case ChatInboxItemKind.saved:
      return 'saved:$id';
    case ChatInboxItemKind.dm:
      return 'dm:$id';
    case ChatInboxItemKind.group:
      return 'group:$id';
    case ChatInboxItemKind.channel:
      return 'channel:$id';
  }
}
