import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';

/// На Windows/Linux `image_picker` с галереей часто не возвращает файл;
/// используем системный выбор файла.
Future<String?> pickImagePathDesktopAware({ImagePicker? imagePicker}) async {
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    return r?.files.single.path;
  }
  final x = await (imagePicker ?? ImagePicker())
      .pickImage(source: ImageSource.gallery);
  return x?.path;
}
