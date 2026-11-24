import 'dart:async';

import 'package:flutter/services.dart';

import 'shared_content_item.dart';

class ShareIntentBridge {
  ShareIntentBridge._();

  static final ShareIntentBridge instance = ShareIntentBridge._();
  static const MethodChannel _channel = MethodChannel('ecc.stellar.app/share');

  final StreamController<List<SharedContentItem>> _sharedContentController =
      StreamController<List<SharedContentItem>>.broadcast();
  bool _initialized = false;

  Stream<List<SharedContentItem>> get sharedContent =>
      _sharedContentController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedContentAvailable') {
        await _takePendingContent();
      }
    });
    await _takePendingContent();
  }

  Future<void> _takePendingContent() async {
    try {
      final response = await _channel.invokeMethod<List<dynamic>>(
        'takePendingSharedContent',
      );
      if (response == null || response.isEmpty) return;
      final items = response
          .whereType<Map<Object?, Object?>>()
          .map(SharedContentItem.fromMap)
          .toList(growable: false);
      if (items.isNotEmpty && !_sharedContentController.isClosed) {
        _sharedContentController.add(items);
      }
    } on MissingPluginException {
      // Sharing is Android-only; other platforms continue to use the picker.
    } on PlatformException {
      // A temporary platform-channel error should not prevent app startup.
    }
  }
}
