import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'attention.dart';
import 'logger.dart';

/// Versioned, bounded notification ledger. No prompts, tokens or tool arguments.
class AttentionStorage {
  static const preferenceKey = 'dsh_attention_ledger_v1';

  Future<void> restore(AttentionLedger ledger) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(preferenceKey);
      if (value == null) return;
      final data = jsonDecode(value);
      if (data is! Map || data['version'] != 1 || data['entries'] is! List) {
        return;
      }
      ledger.restore(
        (data['entries'] as List)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(),
      );
    } catch (_) {
      AppLog.instance.log('通知：账本无法恢复，等待宿主待办快照对账');
    }
  }

  Future<void> save(AttentionLedger ledger) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      preferenceKey,
      jsonEncode({'version': 1, 'entries': ledger.toJson()}),
    );
  }
}
