import 'package:flutter/material.dart';

import '../../services/update_service.dart';

/// Прогресс скачивания обновления (десктоп).
class UpdateProgressDialog extends StatefulWidget {
  final UpdateInfo update;
  const UpdateProgressDialog({super.key, required this.update});

  @override
  State<UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<UpdateProgressDialog> {
  @override
  void initState() {
    super.initState();
    UpdateService.instance.downloadProgress.addListener(_rebuild);
    UpdateService.instance.downloadAndInstall(widget.update);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    UpdateService.instance.downloadProgress.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = UpdateService.instance.downloadProgress.value;
    return AlertDialog(
      title: Text('Обновление ${widget.update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress == null)
            const CircularProgressIndicator()
          else ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text('${(progress * 100).toStringAsFixed(0)}%'),
          ],
          const SizedBox(height: 8),
          const Text('Пожалуйста, не закрывай приложение...'),
        ],
      ),
    );
  }
}
