import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'download.dart';

class DownloadForeground {
  DownloadForeground({
    this.channel = const MethodChannel('dsh/download'),
    bool? enabled,
  }) : _enabled =
           enabled ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static final instance = DownloadForeground();
  final MethodChannel channel;
  final bool _enabled;
  DownloadForegroundLease? _active;
  int _sequence = 0;

  Future<DownloadForegroundLease> start(DownloadCancelToken cancel) async {
    if (_active != null) {
      throw PlatformException(
        code: 'download-in-progress',
        message: 'Another file is downloading',
      );
    }
    final lease = DownloadForegroundLease._(
      this,
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      cancel,
    );
    _active = lease;
    if (!_enabled) return lease;
    channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (call.method == 'paused' &&
          args is Map &&
          _active != null &&
          args['id'] == _active?._id) {
        final active = _active!;
        active.pauseReason = args['reason'] as String?;
        active.backgroundActive = false;
        if (active.pauseReason == 'service-unavailable') {
          active.unavailableReason = 'service-unavailable';
        } else {
          active._cancel.cancel();
        }
      }
    });
    try {
      final state = await channel.invokeMapMethod<String, dynamic>('start', {
        'id': lease._id,
      });
      lease.backgroundActive = state?['running'] == true;
      lease.unavailableReason = state?['reason'] as String?;
      return lease;
    } on MissingPluginException {
      lease.unavailableReason = 'unsupported';
      return lease;
    } on PlatformException catch (error) {
      if (error.code == 'download-in-progress') {
        _active = null;
        rethrow;
      }
      lease.unavailableReason = 'service-unavailable';
      return lease;
    }
  }
}

class DownloadForegroundLease {
  DownloadForegroundLease._(this._owner, this._id, this._cancel);
  final DownloadForeground _owner;
  final String _id;
  final DownloadCancelToken _cancel;
  bool backgroundActive = false;
  String? unavailableReason;
  String? pauseReason;
  bool _closed = false;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastUpdate = -1000;

  void progress(DownloadProgress progress) {
    if (_closed || !backgroundActive) return;
    final now = _clock.elapsedMilliseconds;
    if (now - _lastUpdate < 500 && progress.received != progress.total) return;
    _lastUpdate = now;
    unawaited(
      _owner.channel
          .invokeMethod<void>('progress', {
            'id': _id,
            'received': progress.received,
            'total': progress.total,
          })
          .catchError((Object _) {}),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _clock.stop();
    try {
      if (_owner._enabled) {
        await _owner.channel.invokeMethod<void>('finish', {'id': _id});
      }
    } on MissingPluginException {
      // 其它平台继续保留前台下载与断点恢复。
    } on PlatformException {
      // 引擎被销毁时，原生桥也会收尾服务；断点不受影响。
    } finally {
      if (identical(_owner._active, this)) _owner._active = null;
      backgroundActive = false;
    }
  }
}
