import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../models/shared_collab.dart';
import '../widgets/adaptive_pickers.dart';
import '../widgets/glass_dialog.dart';

/// Диалог создания списка дел. Возвращает закодированный `text` сообщения.
Future<String?> showSharedTodoComposeDialog(BuildContext context) async {
  final titleCtrl = TextEditingController();
  final lines = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];

  final ok = await showAdaptiveGlassDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Список дел'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Заголовок',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Пункты', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              ...lines.asMap().entries.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: TextField(
                      controller: e.value,
                      decoration: InputDecoration(
                        labelText: 'Пункт ${e.key + 1}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  )),
              TextButton.icon(
                onPressed: () {
                  setSt(() => lines.add(TextEditingController()));
                },
                icon: const Icon(Icons.add),
                label: const Text('Добавить пункт'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('В чат'),
          ),
        ],
      ),
    ),
  );

  if (ok != true) return null;
  final uuid = const Uuid();
  final items = <SharedTodoItem>[];
  for (final c in lines) {
    final t = c.text.trim();
    if (t.isEmpty) continue;
    items.add(SharedTodoItem(id: uuid.v4(), text: t));
  }
  if (items.isEmpty) return null;
  return SharedTodoPayload(
    ver: 1,
    title: titleCtrl.text.trim(),
    items: items,
  ).encode();
}

Future<String?> showSharedCalendarComposeDialog(BuildContext context) async {
  final titleCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  var date = DateTime.now();
  var time = TimeOfDay.fromDateTime(DateTime.now());

  final ok = await showAdaptiveGlassDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Событие в календаре'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Дата'),
                subtitle: Text(
                  '${date.day.toString().padLeft(2, '0')}.'
                  '${date.month.toString().padLeft(2, '0')}.${date.year}',
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final d = await showAdaptiveDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) setSt(() => date = d);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Время'),
                subtitle: Text(time.format(ctx)),
                trailing: const Icon(Icons.schedule),
                onTap: () async {
                  final t = await showAdaptiveTimePicker(
                    context: ctx,
                    initialTime: time,
                  );
                  if (t != null) setSt(() => time = t);
                },
              ),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Заметка (необязательно)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('В чат'),
          ),
        ],
      ),
    ),
  );

  if (ok != true) return null;
  final title = titleCtrl.text.trim();
  if (title.isEmpty) return null;
  final start = DateTime(
    date.year,
    date.month,
    date.day,
    time.hour,
    time.minute,
  );
  final note = noteCtrl.text.trim();
  return SharedCalendarPayload(
    ver: 1,
    title: title,
    startMs: start.millisecondsSinceEpoch,
    note: note.isEmpty ? null : note,
  ).encode();
}
