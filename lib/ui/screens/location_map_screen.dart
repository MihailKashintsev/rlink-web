import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class LocationPickResult {
  final double latitude;
  final double longitude;

  const LocationPickResult({
    required this.latitude,
    required this.longitude,
  });
}

Future<void> _launchExternal(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

Future<void> _openDefaultMaps(double lat, double lng) async {
  final googleFallback =
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
  Uri primary;
  if (Platform.isAndroid) {
    primary = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
  } else if (Platform.isIOS) {
    primary = Uri.parse('maps://?q=$lat,$lng&ll=$lat,$lng');
  } else {
    primary = Uri.parse(
      'https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=15/$lat/$lng',
    );
  }

  try {
    final opened =
        await launchUrl(primary, mode: LaunchMode.externalApplication);
    if (!opened) {
      await launchUrl(
        googleFallback,
        mode: LaunchMode.externalApplication,
      );
    }
  } catch (_) {
    await _launchExternal(googleFallback);
  }
}

Future<void> _openGoogleMaps(double lat, double lng) async {
  await _launchExternal(
    Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
  );
}

Future<void> _openYandexMaps(double lat, double lng) async {
  final deep = Uri.parse('yandexmaps://maps.yandex.ru/?pt=$lng,$lat&z=14');
  final web = Uri.parse('https://yandex.ru/maps/?pt=$lng,$lat&z=14&l=map');
  try {
    final opened = await launchUrl(deep, mode: LaunchMode.externalApplication);
    if (!opened) {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    }
  } catch (_) {
    await _launchExternal(web);
  }
}

Future<void> showLocationActionsSheet(
  BuildContext context, {
  required double latitude,
  required double longitude,
  bool includeInAppViewer = true,
}) async {
  final latStr = latitude.toStringAsFixed(6);
  final lngStr = longitude.toStringAsFixed(6);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Wrap(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              '$latStr, $lngStr',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(ctx).hintColor,
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (includeInAppViewer)
            ListTile(
              leading: const Icon(Icons.map_rounded),
              title: const Text('Открыть карту в приложении'),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocationMapScreen(
                        initialLat: latitude,
                        initialLng: longitude,
                        allowPicking: false,
                        title: 'Геолокация',
                        confirmButtonLabel: '',
                      ),
                    ),
                  ),
                );
              },
            ),
          ListTile(
            leading: const Icon(Icons.navigation_outlined),
            title: const Text('Карты по умолчанию'),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_openDefaultMaps(latitude, longitude));
            },
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Google Maps'),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_openGoogleMaps(latitude, longitude));
            },
          ),
          ListTile(
            leading: const Icon(Icons.explore_outlined),
            title: const Text('Яндекс Карты'),
            onTap: () {
              Navigator.of(ctx).pop();
              unawaited(_openYandexMaps(latitude, longitude));
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Скопировать координаты'),
            onTap: () {
              Navigator.of(ctx).pop();
              Clipboard.setData(ClipboardData(text: '$latStr, $lngStr'));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('Координаты скопированы'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

class LocationMapScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;
  final bool allowPicking;
  final String title;
  final String confirmButtonLabel;

  const LocationMapScreen({
    super.key,
    this.initialLat,
    this.initialLng,
    this.allowPicking = true,
    this.title = 'Карта',
    this.confirmButtonLabel = 'Выбрать точку',
  });

  @override
  State<LocationMapScreen> createState() => _LocationMapScreenState();
}

class _LocationMapScreenState extends State<LocationMapScreen> {
  static const _kFallbackLat = 55.751244;
  static const _kFallbackLng = 37.618423;

  final _mapController = MapController();
  final _searchController = TextEditingController();
  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: const {
        'User-Agent': 'Rlink/1.0 (location picker)',
      },
    ),
  );

  late LatLng _selectedPoint;
  bool _searching = false;
  bool _locating = false;
  bool _resolvingAddress = false;
  int _addressRequestToken = 0;
  String? _addressText;

  @override
  void initState() {
    super.initState();
    _selectedPoint = LatLng(
      widget.initialLat ?? _kFallbackLat,
      widget.initialLng ?? _kFallbackLng,
    );
    unawaited(_resolveAddress(_selectedPoint));
    if (widget.initialLat == null || widget.initialLng == null) {
      unawaited(_centerOnMyLocation(showErrors: false));
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _setSelectedPoint(
    LatLng point, {
    bool moveMap = false,
    double zoom = 15,
  }) {
    if (!mounted) return;
    setState(() => _selectedPoint = point);
    if (moveMap) {
      try {
        _mapController.move(point, zoom);
      } catch (_) {}
    }
    unawaited(_resolveAddress(point));
  }

  Future<void> _resolveAddress(LatLng point) async {
    final reqToken = ++_addressRequestToken;
    if (mounted) {
      setState(() => _resolvingAddress = true);
    }
    try {
      final response = await _dio.get(
        'https://nominatim.openstreetmap.org/reverse',
        queryParameters: {
          'format': 'jsonv2',
          'lat': point.latitude.toStringAsFixed(7),
          'lon': point.longitude.toStringAsFixed(7),
          'accept-language': 'ru',
        },
      );
      if (!mounted || reqToken != _addressRequestToken) return;
      final data = response.data;
      var text = '';
      if (data is Map) {
        text = data['display_name']?.toString() ?? '';
      }
      setState(() {
        _addressText = text.isNotEmpty ? text : 'Адрес не найден';
        _resolvingAddress = false;
      });
    } catch (_) {
      if (!mounted || reqToken != _addressRequestToken) return;
      setState(() {
        _addressText = 'Адрес недоступен';
        _resolvingAddress = false;
      });
    }
  }

  Future<void> _searchAddress() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    try {
      final response = await _dio.get(
        'https://nominatim.openstreetmap.org/search',
        queryParameters: {
          'format': 'jsonv2',
          'limit': 1,
          'q': query,
          'accept-language': 'ru',
        },
      );
      final raw = response.data;
      if (raw is List && raw.isNotEmpty) {
        final first = raw.first;
        if (first is Map) {
          final lat = double.tryParse(first['lat']?.toString() ?? '');
          final lng = double.tryParse(first['lon']?.toString() ?? '');
          if (lat != null && lng != null) {
            _setSelectedPoint(LatLng(lat, lng), moveMap: true, zoom: 16);
            return;
          }
        }
      }
      _showSnack('Адрес не найден');
    } catch (_) {
      _showSnack('Поиск адреса недоступен');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _centerOnMyLocation({required bool showErrors}) async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (showErrors) {
          _showSnack('Включите геолокацию в настройках телефона');
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (showErrors) _showSnack('Нет доступа к геолокации');
        return;
      }

      final LocationSettings locationSettings;
      if (Platform.isAndroid) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 15),
          forceLocationManager: true,
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.lowest,
          timeLimit: Duration(seconds: 10),
        );
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );
      if (!mounted) return;
      _setSelectedPoint(
        LatLng(pos.latitude, pos.longitude),
        moveMap: true,
      );
    } catch (_) {
      if (showErrors) _showSnack('Не удалось определить местоположение');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final latStr = _selectedPoint.latitude.toStringAsFixed(6);
    final lngStr = _selectedPoint.longitude.toStringAsFixed(6);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Открыть во внешних картах',
            onPressed: () => showLocationActionsSheet(
              context,
              latitude: _selectedPoint.latitude,
              longitude: _selectedPoint.longitude,
              includeInAppViewer: false,
            ),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _searchAddress(),
                      decoration: InputDecoration(
                        hintText: 'Поиск по адресу',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                tooltip: 'Найти',
                                onPressed: _searchAddress,
                                icon: const Icon(Icons.arrow_forward_rounded),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _selectedPoint,
                      initialZoom: 14,
                      onTap: widget.allowPicking
                          ? (_, point) => _setSelectedPoint(point)
                          : null,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.rlink.app',
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _selectedPoint,
                            width: 56,
                            height: 56,
                            child: Icon(
                              Icons.location_on_rounded,
                              size: 44,
                              color: cs.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (widget.allowPicking)
                    Positioned(
                      top: 10,
                      left: 12,
                      right: 12,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text(
                            'Нажмите по карте, чтобы выбрать точку',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                  top: BorderSide(color: cs.outline.withValues(alpha: 0.2)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$latStr, $lngStr',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _resolvingAddress
                        ? 'Определяем адрес...'
                        : (_addressText ?? 'Адрес не найден'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.8),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _locating
                              ? null
                              : () => _centerOnMyLocation(showErrors: true),
                          icon: _locating
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.my_location_rounded),
                          label: Text(
                              _locating ? 'Определяем...' : 'Мое положение'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => showLocationActionsSheet(
                            context,
                            latitude: _selectedPoint.latitude,
                            longitude: _selectedPoint.longitude,
                            includeInAppViewer: false,
                          ),
                          icon: const Icon(Icons.map_outlined),
                          label: const Text('Внешние карты'),
                        ),
                      ),
                    ],
                  ),
                  if (widget.allowPicking) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop(
                            LocationPickResult(
                              latitude: _selectedPoint.latitude,
                              longitude: _selectedPoint.longitude,
                            ),
                          );
                        },
                        icon: const Icon(Icons.check_rounded),
                        label: Text(widget.confirmButtonLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
