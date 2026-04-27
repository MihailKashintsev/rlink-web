import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'runtime_platform.dart';

enum ActionSound {
  messageSent,
  messageReceived,
  callConnected,
}

class SoundEffectsService {
  SoundEffectsService._();
  static final SoundEffectsService instance = SoundEffectsService._();

  final AudioPlayer _effectsPlayer = AudioPlayer(playerId: 'rlink_fx');
  final AudioPlayer _ringtonePlayer = AudioPlayer(playerId: 'rlink_ringtone');

  bool get _enabled => AppSettings.instance.notifSound;
  bool get _supportedPlatform =>
      RuntimePlatform.isAndroid ||
      RuntimePlatform.isIos ||
      RuntimePlatform.isDesktop;

  Future<void> playAction(ActionSound sound) async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      final bytes = switch (sound) {
        ActionSound.messageSent => _buildToneBytes(
            notes: const [1200],
            stepMs: 70,
            sampleRate: 16000,
            amplitude: 0.20,
          ),
        ActionSound.messageReceived => _buildToneBytes(
            notes: const [740, 990],
            stepMs: 95,
            sampleRate: 16000,
            amplitude: 0.23,
          ),
        ActionSound.callConnected => _buildToneBytes(
            notes: const [660, 880, 660],
            stepMs: 80,
            sampleRate: 16000,
            amplitude: 0.22,
          ),
      };
      await _effectsPlayer.setReleaseMode(ReleaseMode.stop);
      await _effectsPlayer.play(BytesSource(bytes), volume: 1);
    } catch (e) {
      debugPrint('[RLINK][Sound] playAction failed: $e');
    }
  }

  Future<void> playPushNotificationSound() async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      final bytes = _buildToneBytes(
        notes: const [820, 1240, 820],
        stepMs: 110,
        sampleRate: 16000,
        amplitude: 0.26,
      );
      await _effectsPlayer.setReleaseMode(ReleaseMode.stop);
      await _effectsPlayer.play(BytesSource(bytes), volume: 1);
    } catch (e) {
      debugPrint('[RLINK][Sound] playPushNotificationSound failed: $e');
    }
  }

  Future<void> startIncomingRingtone() async {
    if (!_enabled || !_supportedPlatform) return;
    try {
      final bytes = _buildRingtonePresetBytes(AppSettings.instance.callRingtone);
      await _ringtonePlayer.stop();
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      await _ringtonePlayer.play(BytesSource(bytes), volume: 1);
    } catch (e) {
      debugPrint('[RLINK][Sound] startIncomingRingtone failed: $e');
    }
  }

  Future<void> stopIncomingRingtone() async {
    try {
      await _ringtonePlayer.stop();
    } catch (_) {}
  }

  Uint8List _buildRingtonePresetBytes(int preset) {
    switch (preset.clamp(0, 2)) {
      case 1:
        return _buildToneBytes(
          notes: const [520, 620, 780, 620],
          stepMs: 170,
          pauseAfterMs: 260,
          sampleRate: 16000,
          amplitude: 0.26,
        );
      case 2:
        return _buildToneBytes(
          notes: const [420, 420, 560],
          stepMs: 210,
          pauseAfterMs: 300,
          sampleRate: 16000,
          amplitude: 0.22,
        );
      case 0:
      default:
        return _buildToneBytes(
          notes: const [660, 880],
          stepMs: 230,
          pauseAfterMs: 320,
          sampleRate: 16000,
          amplitude: 0.28,
        );
    }
  }

  Uint8List _buildToneBytes({
    required List<int> notes,
    required int stepMs,
    int pauseAfterMs = 0,
    int sampleRate = 16000,
    double amplitude = 0.25,
  }) {
    final pcm = BytesBuilder();
    final totalSteps = <int>[...notes];
    final maxAmp = (32767 * amplitude).round().clamp(0, 32767);
    for (final freq in totalSteps) {
      final samples = ((stepMs / 1000) * sampleRate).round();
      for (var i = 0; i < samples; i++) {
        final t = i / sampleRate;
        final fadeIn = i < 80 ? i / 80 : 1.0;
        final fadeOut =
            i > samples - 100 ? ((samples - i).clamp(0, 100)) / 100.0 : 1.0;
        final env = fadeIn * fadeOut;
        final val = (math.sin(2 * math.pi * freq * t) * maxAmp * env).round();
        pcm.addByte(val & 0xff);
        pcm.addByte((val >> 8) & 0xff);
      }
    }
    if (pauseAfterMs > 0) {
      final pauseSamples = ((pauseAfterMs / 1000) * sampleRate).round();
      for (var i = 0; i < pauseSamples; i++) {
        pcm.addByte(0);
        pcm.addByte(0);
      }
    }
    return _wrapPcm16MonoWav(
      pcm.toBytes(),
      sampleRate: sampleRate,
    );
  }

  Uint8List _wrapPcm16MonoWav(
    Uint8List pcm, {
    required int sampleRate,
  }) {
    final byteRate = sampleRate * 2;
    const blockAlign = 2;
    final dataSize = pcm.length;
    final fileSize = 36 + dataSize;
    final out = BytesBuilder();
    void addAscii(String s) => out.add(s.codeUnits);
    void addU32(int v) {
      out.addByte(v & 0xff);
      out.addByte((v >> 8) & 0xff);
      out.addByte((v >> 16) & 0xff);
      out.addByte((v >> 24) & 0xff);
    }

    void addU16(int v) {
      out.addByte(v & 0xff);
      out.addByte((v >> 8) & 0xff);
    }

    addAscii('RIFF');
    addU32(fileSize);
    addAscii('WAVE');
    addAscii('fmt ');
    addU32(16);
    addU16(1);
    addU16(1);
    addU32(sampleRate);
    addU32(byteRate);
    addU16(blockAlign);
    addU16(16);
    addAscii('data');
    addU32(dataSize);
    out.add(pcm);
    return out.toBytes();
  }
}
