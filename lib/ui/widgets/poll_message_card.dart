import 'package:flutter/material.dart';

import '../../models/message_poll.dart';
import '../../services/broadcast_outbox_service.dart';
import '../../services/channel_service.dart';
import '../../services/crypto_service.dart';
import '../../services/group_service.dart';

/// Карточка опроса для поста канала или сообщения группы.
class PollMessageCard extends StatefulWidget {
  final String targetId;
  final String kind; // channel_post | group_message
  final MessagePoll poll;
  final ColorScheme cs;
  final bool isOutgoing;
  final bool compact;

  const PollMessageCard({
    super.key,
    required this.targetId,
    required this.kind,
    required this.poll,
    required this.cs,
    this.isOutgoing = false,
    this.compact = false,
  });

  @override
  State<PollMessageCard> createState() => _PollMessageCardState();
}

class _PollMessageCardState extends State<PollMessageCard> {
  final Set<int> _multiSel = {};

  Future<void> _submitVote(List<int> choices) async {
    if (choices.isEmpty) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (widget.kind == 'channel_post') {
      await ChannelService.instance.applyPollVote(widget.targetId, myId, choices);
    } else {
      await GroupService.instance.applyPollVote(widget.targetId, myId, choices);
    }
    await BroadcastOutboxService.instance.enqueuePollVote(
      kind: widget.kind,
      targetId: widget.targetId,
      voterId: myId,
      choiceIndices: choices,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    final cs = widget.cs;
    final isOutgoing = widget.isOutgoing;
    final myId = CryptoService.instance.publicKeyHex;
    final ord = poll.displayOrder(widget.targetId);
    final counts = poll.counts;
    final totalVotes = poll.votes.values.fold<int>(0, (a, v) => a + v.length);
    final myVotes = poll.votes[myId] ?? const <int>[];
    final voted = myVotes.isNotEmpty;
    // Иначе у не голосовавших пропадают кнопки, как только кто-то другой проголосовал.
    final showResults = voted;
    final border = cs.outline.withValues(alpha: 0.25);
    final bg = isOutgoing
        ? Colors.black.withValues(alpha: 0.12)
        : cs.surfaceContainerHighest.withValues(alpha: 0.35);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  poll.question.isEmpty ? 'Опрос' : poll.question,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: widget.compact ? 13 : 14,
                    color: isOutgoing ? cs.onPrimary : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (poll.anonymous || poll.multiSelect || poll.quiz || poll.randomOrder)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  if (poll.anonymous) _chip(cs, 'Анонимно', isOutgoing),
                  if (poll.multiSelect) _chip(cs, 'Несколько', isOutgoing),
                  if (poll.quiz) _chip(cs, 'Викторина', isOutgoing),
                  if (poll.randomOrder) _chip(cs, 'Перемешано', isOutgoing),
                ],
              ),
            ),
          const SizedBox(height: 8),
          ...List.generate(ord.length, (displayIdx) {
            final srcIdx = ord[displayIdx];
            final label = poll.options[srcIdx];
            final c = srcIdx < counts.length ? counts[srcIdx] : 0;
            final pct = totalVotes > 0 ? c / totalVotes : 0.0;
            final isCorrect =
                poll.quiz && voted && poll.correctIndex == srcIdx;
            final isWrong = poll.quiz &&
                voted &&
                myVotes.contains(srcIdx) &&
                poll.correctIndex != srcIdx;

            if (!voted && !showResults) {
              if (poll.multiSelect) {
                final checked = _multiSel.contains(srcIdx);
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: checked,
                  title: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: isOutgoing ? cs.onPrimary : cs.onSurface,
                    ),
                  ),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _multiSel.add(srcIdx);
                      } else {
                        _multiSel.remove(srcIdx);
                      }
                    });
                  },
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _submitVote([srcIdx]),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: border),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          color: isOutgoing ? cs.onPrimary : cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isCorrect
                                ? Colors.green
                                : isWrong
                                    ? Colors.redAccent
                                    : (isOutgoing
                                        ? cs.onPrimary
                                        : cs.onSurface),
                          ),
                        ),
                      ),
                      if (showResults || voted)
                        Text(
                          '$c · ${(pct * 100).round()}%',
                          style: TextStyle(
                            fontSize: 12,
                            color: (isOutgoing ? cs.onPrimary : cs.onSurface)
                                .withValues(alpha: 0.6),
                          ),
                        ),
                    ],
                  ),
                  if (showResults || voted) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: pct.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor:
                            cs.outline.withValues(alpha: 0.15),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isCorrect
                              ? Colors.green
                              : cs.primary.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
          if (!voted && poll.multiSelect && !showResults) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _multiSel.isEmpty
                    ? null
                    : () => _submitVote(_multiSel.toList()..sort()),
                child: const Text('Голосовать'),
              ),
            ),
          ],
          if (poll.anonymous && totalVotes > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Голосов: $totalVotes',
                style: TextStyle(
                  fontSize: 11,
                  color: (isOutgoing ? cs.onPrimary : cs.onSurface)
                      .withValues(alpha: 0.45),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(ColorScheme cs, String label, bool isOut) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: isOut ? cs.onPrimary : cs.primary,
        ),
      ),
    );
  }
}
