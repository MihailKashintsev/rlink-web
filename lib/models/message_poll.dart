import 'dart:convert';
import 'dart:math';

/// Опрос для групп/каналов (JSON в [poll_json] / gossip `pj`).
class MessagePoll {
  final String question;
  final List<String> options;
  final bool anonymous;
  final bool quiz;
  final bool multiSelect;
  final bool randomOrder;
  final int? correctIndex;
  /// userId → выбранные **исходные** индексы вариантов (0..options.length-1).
  final Map<String, List<int>> votes;

  const MessagePoll({
    required this.question,
    required this.options,
    this.anonymous = false,
    this.quiz = false,
    this.multiSelect = false,
    this.randomOrder = false,
    this.correctIndex,
    this.votes = const {},
  });

  /// Порядок **исходных** индексов для отображения (при randomOrder — детерминированно от [messageId]).
  List<int> displayOrder(String messageId) {
    final o = List<int>.generate(options.length, (i) => i);
    if (randomOrder) o.shuffle(Random(messageId.hashCode));
    return o;
  }

  List<String> displayLabels(String messageId) {
    final ord = displayOrder(messageId);
    return [for (final i in ord) options[i]];
  }

  Map<String, dynamic> toJson() => {
        'q': question,
        'o': options,
        'a': anonymous,
        'z': quiz,
        'm': multiSelect,
        'r': randomOrder,
        if (correctIndex != null) 'c': correctIndex,
        'v': votes.map((k, v) => MapEntry(k, v)),
      };

  factory MessagePoll.fromJson(Map<String, dynamic> j) {
    Map<String, List<int>> v = {};
    final rawV = j['v'];
    if (rawV is Map) {
      for (final e in rawV.entries) {
        final list = e.value;
        if (list is List) {
          v[e.key.toString()] = list.map((x) => (x as num).toInt()).toList();
        }
      }
    }
    final opts = (j['o'] as List?)?.map((e) => e.toString()).toList() ?? [];
    return MessagePoll(
      question: j['q']?.toString() ?? '',
      options: opts,
      anonymous: j['a'] == true,
      quiz: j['z'] == true,
      multiSelect: j['m'] == true,
      randomOrder: j['r'] == true,
      correctIndex: j['c'] is int ? j['c'] as int : (j['c'] as num?)?.toInt(),
      votes: v,
    );
  }

  String encode() => jsonEncode(toJson());

  static MessagePoll? tryDecode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return MessagePoll.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  MessagePoll withVote(String voterId, List<int> choiceIndices) {
    final v = Map<String, List<int>>.from(votes);
    v[voterId] = List<int>.from(choiceIndices);
    return MessagePoll(
      question: question,
      options: options,
      anonymous: anonymous,
      quiz: quiz,
      multiSelect: multiSelect,
      randomOrder: randomOrder,
      correctIndex: correctIndex,
      votes: v,
    );
  }

  List<int> get counts {
    final c = List<int>.filled(options.length, 0);
    for (final choices in votes.values) {
      for (final i in choices) {
        if (i >= 0 && i < c.length) c[i]++;
      }
    }
    return c;
  }

  /// Слияние голосов из другого снимка (P2P / история / poll_vote).
  MessagePoll mergeVotesFrom(MessagePoll? other) {
    if (other == null) return this;
    final v = Map<String, List<int>>.from(votes);
    other.votes.forEach((k, val) => v[k] = List<int>.from(val));
    return MessagePoll(
      question: question,
      options: options,
      anonymous: anonymous,
      quiz: quiz,
      multiSelect: multiSelect,
      randomOrder: randomOrder,
      correctIndex: correctIndex,
      votes: v,
    );
  }
}
