import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/sticker_pack.dart';
import '../../services/sticker_collection_service.dart';
import 'desktop_image_picker.dart';
import 'sticker_crop_screen.dart';

const _kRecentFilesPrefKey = 'media_gallery_recent_files_v1';
const _kMaxRecentFiles = 24;

bool get _useNativePhotoGrid {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}

bool _isGifMime(String? m) =>
    m != null && m.toLowerCase().contains('gif');

Future<void> _rememberFilePath(String path) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecentFilesPrefKey);
    var list = <String>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        list = (jsonDecode(raw) as List).cast<String>();
      } catch (_) {}
    }
    list = [path, ...list.where((p) => p != path)];
    if (list.length > _kMaxRecentFiles) {
      list = list.sublist(0, _kMaxRecentFiles);
    }
    await prefs.setString(_kRecentFilesPrefKey, jsonEncode(list));
  } catch (_) {}
}

Future<List<String>> _loadRecentFilePaths() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecentFilesPrefKey);
    if (raw == null || raw.isEmpty) return [];
    final list = (jsonDecode(raw) as List).cast<String>();
    return list.where((p) => File(p).existsSync()).toList();
  } catch (_) {
    return [];
  }
}

/// Вкладки: коллекция стикеров / GIF / фото / видео / файлы (включая недавние).
Future<void> showMediaGallerySendSheet(
  BuildContext context, {
  required Future<void> Function(String filePath) onPhotoPath,
  required Future<void> Function(String filePath) onGifPath,
  required Future<void> Function(String filePath) onVideoPath,
  required Future<void> Function(Uint8List croppedBytes) onStickerCropped,
  required Future<void> Function(String stickerLibraryFilePath)
      onStickerFromLibrary,
  required Future<void> Function(String filePath) onFilePath,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.95,
        builder: (context, _) {
          return DefaultTabController(
            length: 5,
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const TabBar(
                  isScrollable: true,
                  tabs: [
                    Tab(text: 'Стикеры'),
                    Tab(text: 'GIF'),
                    Tab(text: 'Фото'),
                    Tab(text: 'Видео'),
                    Tab(text: 'Файлы'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _StickerLibraryTab(
                        sheetContext: ctx,
                        onStickerFromLibrary: onStickerFromLibrary,
                        onStickerCropped: onStickerCropped,
                      ),
                      _GalleryTab(
                        mode: _GalleryMode.gif,
                        onPhotoPath: onPhotoPath,
                        onGifPath: onGifPath,
                        onVideoPath: onVideoPath,
                        sheetContext: ctx,
                      ),
                      _GalleryTab(
                        mode: _GalleryMode.photo,
                        onPhotoPath: onPhotoPath,
                        onGifPath: onGifPath,
                        onVideoPath: onVideoPath,
                        sheetContext: ctx,
                      ),
                      _GalleryTab(
                        mode: _GalleryMode.video,
                        onPhotoPath: onPhotoPath,
                        onGifPath: onGifPath,
                        onVideoPath: onVideoPath,
                        sheetContext: ctx,
                      ),
                      _FilesGalleryTab(
                        sheetContext: ctx,
                        onFilePath: onFilePath,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class _StickerLibraryTab extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String path) onStickerFromLibrary;
  final Future<void> Function(Uint8List cropped) onStickerCropped;

  const _StickerLibraryTab({
    required this.sheetContext,
    required this.onStickerFromLibrary,
    required this.onStickerCropped,
  });

  @override
  State<_StickerLibraryTab> createState() => _StickerLibraryTabState();
}

class _StickerLibraryTabState extends State<_StickerLibraryTab> {
  List<File> _files = [];
  List<StickerPack> _packs = [];
  int _allStickerCount = 0;
  String? _filterPackId;
  bool _loading = true;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    StickerCollectionService.instance.version.addListener(_reload);
    unawaited(_reload());
  }

  @override
  void dispose() {
    StickerCollectionService.instance.version.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _loading = true);
    await StickerCollectionService.instance.ensureInitialized();
    if (!mounted) return;
    final packs = await StickerCollectionService.instance.loadPacks();
    if (!mounted) return;
    final allFlat =
        await StickerCollectionService.instance.stickerFilesNewestFirst();
    if (!mounted) return;
    var filter = _filterPackId;
    if (filter != null && !packs.any((p) => p.id == filter)) {
      filter = null;
    }
    final files = await StickerCollectionService.instance
        .stickerFilesForPack(filter);
    if (mounted) {
      setState(() {
        _packs = packs;
        _filterPackId = filter;
        _allStickerCount = allFlat.length;
        _files = files;
        _loading = false;
      });
    }
  }

  Future<void> _createFromPhoto() async {
    final nav = Navigator.of(context);
    final sheetNav = Navigator.of(widget.sheetContext);
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;
    if (picked.path.toLowerCase().endsWith('.gif')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для GIF откройте вкладку «GIF»')),
      );
      return;
    }
    final bytes = await File(picked.path).readAsBytes();
    if (!mounted) return;
    final cropped = await nav.push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StickerCropScreen(imageBytes: bytes),
      ),
    );
    if (!mounted) return;
    if (cropped != null) {
      sheetNav.pop();
      await widget.onStickerCropped(cropped);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty && _allStickerCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.emoji_emotions_outlined,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                'Здесь стикеры, которые вы отправляли или добавляли из чатов',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _createFromPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Создать стикер из фото'),
              ),
            ],
          ),
        ),
      );
    }
    if (_files.isEmpty && _allStickerCount > 0) {
      return Column(
        children: [
          if (_packs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: DropdownButtonFormField<String?>(
                value: _filterPackId,
                decoration: const InputDecoration(
                  labelText: 'Набор',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Все стикеры'),
                  ),
                  ..._packs.map(
                    (p) => DropdownMenuItem<String?>(
                      value: p.id,
                      child: Text(
                        p.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (v) {
                  setState(() => _filterPackId = v);
                  unawaited(_reload());
                },
              ),
            ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'В этом наборе пока нет стикеров. Выберите «Все стикеры» '
                  'или добавьте стикеры в набор в Настройки → Стикеры.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (_packs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: DropdownButtonFormField<String?>(
              value: _filterPackId,
              decoration: const InputDecoration(
                labelText: 'Набор',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Все стикеры'),
                ),
                ..._packs.map(
                  (p) => DropdownMenuItem<String?>(
                    value: p.id,
                    child: Text(
                      p.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (v) {
                setState(() => _filterPackId = v);
                unawaited(_reload());
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _createFromPhoto,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Новый стикер из фото'),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(6),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: _files.length,
            itemBuilder: (context, i) {
              final f = _files[i];
              return GestureDetector(
                onTap: () async {
                  final sheetNav = Navigator.of(widget.sheetContext);
                  sheetNav.pop();
                  await widget.onStickerFromLibrary(f.path);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(f, fit: BoxFit.cover),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FilesGalleryTab extends StatefulWidget {
  final BuildContext sheetContext;
  final Future<void> Function(String path) onFilePath;

  const _FilesGalleryTab({
    required this.sheetContext,
    required this.onFilePath,
  });

  @override
  State<_FilesGalleryTab> createState() => _FilesGalleryTabState();
}

class _FilesGalleryTabState extends State<_FilesGalleryTab> {
  List<String> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final r = await _loadRecentFilePaths();
    if (mounted) {
      setState(() {
        _recent = r;
        _loading = false;
      });
    }
  }

  Future<void> _browse() async {
    final sheetNav = Navigator.of(widget.sheetContext);
    final r = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    await _rememberFilePath(path);
    sheetNav.pop();
    await widget.onFilePath(path);
  }

  Future<void> _pickRecent(String path) async {
    final sheetNav = Navigator.of(widget.sheetContext);
    sheetNav.pop();
    await _rememberFilePath(path);
    await widget.onFilePath(path);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _browse,
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('Выбрать файл'),
          ),
        ),
        if (_recent.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'Недавно выбранные файлы появятся здесь',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _recent.length,
              itemBuilder: (context, i) {
                final p = _recent[i];
                final name = p.split(Platform.pathSeparator).last;
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    p,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  onTap: () => unawaited(_pickRecent(p)),
                );
              },
            ),
          ),
      ],
    );
  }
}

enum _GalleryMode { gif, photo, video }

class _GalleryTab extends StatefulWidget {
  final _GalleryMode mode;
  final Future<void> Function(String filePath) onPhotoPath;
  final Future<void> Function(String filePath) onGifPath;
  final Future<void> Function(String filePath) onVideoPath;
  final BuildContext sheetContext;

  const _GalleryTab({
    required this.mode,
    required this.onPhotoPath,
    required this.onGifPath,
    required this.onVideoPath,
    required this.sheetContext,
  });

  @override
  State<_GalleryTab> createState() => _GalleryTabState();
}

class _GalleryTabState extends State<_GalleryTab> {
  List<AssetEntity>? _assets;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (_useNativePhotoGrid) {
      _loadNative();
    } else {
      _loading = false;
    }
  }

  Future<void> _loadNative() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await PhotoManager.requestPermissionExtend();
      if (!state.hasAccess) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Нет доступа к галерее';
            _assets = [];
          });
        }
        return;
      }

      final type = widget.mode == _GalleryMode.video
          ? RequestType.video
          : RequestType.image;

      final paths = await PhotoManager.getAssetPathList(
        type: type,
        hasAll: true,
        onlyAll: true,
      );
      if (paths.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _assets = [];
          });
        }
        return;
      }

      final album = paths.first;
      final raw = await album.getAssetListPaged(page: 0, size: 120);

      List<AssetEntity> filtered = raw;
      if (widget.mode == _GalleryMode.gif) {
        final withMime = await Future.wait(
          raw.map((e) async {
            final m = await e.mimeTypeAsync;
            return _isGifMime(m);
          }),
        );
        filtered = [
          for (var i = 0; i < raw.length; i++)
            if (withMime[i]) raw[i],
        ];
      } else if (widget.mode == _GalleryMode.photo) {
        final withMime = await Future.wait(
          raw.map((e) async {
            final m = await e.mimeTypeAsync;
            return !_isGifMime(m);
          }),
        );
        filtered = [
          for (var i = 0; i < raw.length; i++)
            if (withMime[i]) raw[i],
        ];
      }

      if (mounted) {
        setState(() {
          _assets = filtered;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
          _assets = [];
        });
      }
    }
  }

  Future<void> _onTapAsset(AssetEntity asset) async {
    final sheetNav = Navigator.of(widget.sheetContext);

    final file = await asset.file;
    if (file == null || !mounted) return;
    final path = file.path;

    switch (widget.mode) {
      case _GalleryMode.gif:
        if (!mounted) return;
        sheetNav.pop();
        await widget.onGifPath(path);
        break;
      case _GalleryMode.photo:
        if (!mounted) return;
        sheetNav.pop();
        await widget.onPhotoPath(path);
        break;
      case _GalleryMode.video:
        if (!mounted) return;
        sheetNav.pop();
        await widget.onVideoPath(path);
        break;
    }
  }

  Future<void> _desktopPick() async {
    final sheetNav = Navigator.of(widget.sheetContext);

    switch (widget.mode) {
      case _GalleryMode.gif:
        final r = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['gif'],
        );
        final path = r?.files.single.path;
        if (path == null || !mounted) return;
        sheetNav.pop();
        await widget.onGifPath(path);
        break;
      case _GalleryMode.photo:
        final raw = await pickImagePathDesktopAware();
        if (raw == null || !mounted) return;
        sheetNav.pop();
        await widget.onPhotoPath(raw);
        break;
      case _GalleryMode.video:
        final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
        if (picked == null || !mounted) return;
        sheetNav.pop();
        await widget.onVideoPath(picked.path);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_useNativePhotoGrid) {
      return _DesktopPlaceholder(
        mode: widget.mode,
        onPressed: _desktopPick,
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadNative,
                child: const Text('Повторить'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: PhotoManager.openSetting,
                child: const Text('Настройки доступа'),
              ),
            ],
          ),
        ),
      );
    }

    final assets = _assets ?? [];
    if (assets.isEmpty) {
      return Center(
        child: Text(
          widget.mode == _GalleryMode.gif
              ? 'Нет GIF в галерее'
              : 'Нет элементов',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: assets.length,
      itemBuilder: (context, index) {
        final asset = assets[index];
        return GestureDetector(
          onTap: () => _onTapAsset(asset),
          child: FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(
              const ThumbnailSize.square(220),
            ),
            builder: (context, snap) {
              final d = snap.data;
              if (d == null) {
                return Container(color: Colors.grey.shade800);
              }
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(d, fit: BoxFit.cover),
                  if (asset.type == AssetType.video)
                    const Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.play_circle_fill,
                            color: Colors.white, size: 22),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _DesktopPlaceholder extends StatelessWidget {
  final _GalleryMode mode;
  final VoidCallback onPressed;

  const _DesktopPlaceholder({
    required this.mode,
    required this.onPressed,
  });

  String get _label {
    switch (mode) {
      case _GalleryMode.gif:
        return 'Выбрать GIF';
      case _GalleryMode.photo:
        return 'Выбрать фото';
      case _GalleryMode.video:
        return 'Выбрать видео';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.folder_open_rounded),
          label: Text(_label),
        ),
      ),
    );
  }
}
