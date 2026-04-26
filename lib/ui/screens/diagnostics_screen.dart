import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/diagnostics_log_service.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Диагностика сети'),
        actions: [
          IconButton(
            tooltip: 'Очистить лог',
            onPressed: DiagnosticsLogService.instance.clear,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Скопировать',
            onPressed: () async {
              final text = DiagnosticsLogService.instance.dump();
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Лог скопирован')),
              );
            },
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: DiagnosticsLogService.instance.entries,
        builder: (_, entries, __) {
          if (entries.isEmpty) {
            return const Center(
              child: Text('Лог пуст. Выполните отправку сообщения/запроса.'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: entries.length,
            itemBuilder: (_, i) => SelectableText(
              entries[i],
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.35,
              ),
            ),
          );
        },
      ),
    );
  }
}
