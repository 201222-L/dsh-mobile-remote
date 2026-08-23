// M1 自动更新：签名 manifest 解析与验签（RFC 8785 JCS + Ed25519 多签名）。
// 信任链：内置公钥集（trusted_keys.dart）→ 至少一个签名项 keyId 命中且验签通过 → 字段/结构校验。
// 错误以 UpdateManifestException(code) 抛出；code 供 UI/测试区分语义。
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'jcs.dart';
import 'trusted_keys.dart';

class UpdateManifestException implements Exception {
  final String code;
  final String message;
  UpdateManifestException(this.code, this.message);
  @override
  String toString() => 'UpdateManifestException($code): $message';
}

class UpdateArtifact {
  final String artifactId;
  final String fileName;
  final String versionName;
  final int? versionCode; // 仅 app 产物
  final int sizeBytes;
  final String sha256;
  UpdateArtifact({
    required this.artifactId,
    required this.fileName,
    required this.versionName,
    this.versionCode,
    required this.sizeBytes,
    required this.sha256,
  });
}

class UpdateManifest {
  final int schemaVersion;
  final int sequence;
  final String channel;
  final String publishedAt;
  final String minPluginVersion;
  final int minAppVersionCode;
  final int? minKeyringVersionCode;
  final UpdateArtifact app;
  final UpdateArtifact plugin;
  UpdateManifest({
    required this.schemaVersion,
    required this.sequence,
    required this.channel,
    required this.publishedAt,
    required this.minPluginVersion,
    required this.minAppVersionCode,
    this.minKeyringVersionCode,
    required this.app,
    required this.plugin,
  });
}

/// base64url 解码（容忍缺 padding；-/_ 归一）。
Uint8List b64urlDecode(String s) {
  var t = s.replaceAll('-', '+').replaceAll('_', '/');
  switch (t.length % 4) {
    case 2:
      t += '==';
    case 3:
      t += '=';
  }
  return base64.decode(t);
}

/// 解码 JSON 键文本中的转义序列（\\ / \uXXXX / \n\t\r\b\f / 代理对），
/// 用于重复键检测——`{"a":1,"\u0061":2}` 的键是等价的。
String _decodeJsonKey(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      switch (n) {
        case 'n': out.write('\n'); i += 2; continue;
        case 't': out.write('\t'); i += 2; continue;
        case 'r': out.write('\r'); i += 2; continue;
        case 'b': out.write('\b'); i += 2; continue;
        case 'f': out.write('\f'); i += 2; continue;
        case '/': out.write('/'); i += 2; continue;
        case '"': out.write('"'); i += 2; continue;
        case '\\': out.write('\\'); i += 2; continue;
        case 'u':
          if (i + 5 < s.length) {
            final cp = int.tryParse(s.substring(i + 2, i + 6), radix: 16);
            if (cp != null) {
              // 代理对（高代理后跟 \uXXXX 低代理）→ 组合码点
              if (cp >= 0xD800 && cp <= 0xDBFF &&
                  i + 11 < s.length && s[i + 6] == '\\' && s[i + 7] == 'u') {
                final lo = int.tryParse(s.substring(i + 8, i + 12), radix: 16);
                if (lo != null && lo >= 0xDC00 && lo <= 0xDFFF) {
                  out.writeCharCode(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
                  i += 12;
                  continue;
                }
              }
              out.writeCharCode(cp);
              i += 6;
              continue;
            }
          }
          out.write(ch); i++; continue;
        default:
          out.write(ch); i++; continue;
      }
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// 检测 JSON 原始字节中的重复键（jsonDecode 会静默折叠重复键；验签要求拒绝）。
/// 键在词法层解码转义后比较（`a` 与 `\u0061` 视为同一键）。
bool hasDuplicateKeys(String text) {
  final stack = <Set<String>>[];
  var inStr = false;
  var escaped = false;
  var keyStart = -1;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (inStr) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inStr = false;
        // 字符串结束：看下一个非空白字符是否为 ':'（键）
        var j = i + 1;
        while (j < text.length && (text[j] == ' ' || text[j] == '\t' || text[j] == '\r' || text[j] == '\n')) {
          j++;
        }
        if (j < text.length && text[j] == ':' && stack.isNotEmpty) {
          final key = _decodeJsonKey(text.substring(keyStart + 1, i));
          if (!stack.last.add(key)) return true;
        }
      }
    } else {
      if (ch == '"') {
        inStr = true;
        escaped = false;
        keyStart = i;
      } else if (ch == '{') {
        stack.add(<String>{});
      } else if (ch == '}') {
        if (stack.isEmpty) return true; // 非法 JSON，交 jsonDecode 报错即可；此处保守返回 true
        stack.removeLast();
      }
    }
    i++;
  }
  return false;
}

/// 解析并验签 manifest。
/// 返回 (manifest, verifiedKeyId)；任一环节失败抛 UpdateManifestException。
Future<(UpdateManifest, String)> parseAndVerifyManifest(
  String raw, {
  Map<String, String> trustedKeys = trustedReleaseKeys,
}) async {
  if (hasDuplicateKeys(raw)) {
    throw UpdateManifestException('duplicate-key', 'manifest 含重复键');
  }
  final Object? doc;
  try {
    doc = jsonDecode(raw);
  } catch (e) {
    throw UpdateManifestException('invalid-json', 'manifest 非合法 JSON: $e');
  }
  if (doc is! Map) {
    throw UpdateManifestException('not-object', 'manifest 顶层必须是对象');
  }
  const allowedTop = {
    'schemaVersion', 'sequence', 'channel', 'publishedAt',
    'minPluginVersion', 'minAppVersionCode', 'minKeyringVersionCode',
    'artifacts', 'signatures',
  };
  for (final k in doc.keys) {
    if (!allowedTop.contains(k)) {
      throw UpdateManifestException('unknown-field', '未知字段: $k');
    }
  }
  final schemaVersion = doc['schemaVersion'];
  if (schemaVersion != 1) {
    throw UpdateManifestException('schema-version', '不支持的 schemaVersion: $schemaVersion');
  }

  // 提取并剔除 signatures，验签对象 = 其余字段的 JCS
  final sigs = doc['signatures'];
  if (sigs is! List || sigs.isEmpty) {
    throw UpdateManifestException('missing-field', 'signatures 缺失或为空');
  }
  final without = Map<dynamic, dynamic>.of(doc)..remove('signatures');

  final m = _fromMap(without);
  final payload = utf8.encode(jcs(without));

  for (final entry in sigs) {
    if (entry is! Map) continue;
    final keyId = entry['keyId'];
    final sig = entry['signature'];
    if (keyId is! String || sig is! String || sig.isEmpty) continue;
    final pubRaw = trustedKeys[keyId];
    if (pubRaw == null) continue;
    try {
      final ok = await Ed25519().verify(
        payload,
        signature: Signature(
          b64urlDecode(sig),
          publicKey: SimplePublicKey(b64urlDecode(pubRaw), type: KeyPairType.ed25519),
        ),
      );
      if (ok) return (m, keyId);
    } catch (_) {
      // 该签名项非法，继续尝试其它
    }
  }
  throw UpdateManifestException('signature-invalid', '无有效签名（受信密钥均不匹配或验签失败）');
}

UpdateManifest _fromMap(Map doc) {
  int intField(String k) {
    final v = doc[k];
    if (v is! int) throw UpdateManifestException('bad-type', '$k 必须是整数');
    return v;
  }

  String strField(String k) {
    final v = doc[k];
    if (v is! String) throw UpdateManifestException('bad-type', '$k 必须是字符串');
    return v;
  }

  final artifacts = doc['artifacts'];
  if (artifacts is! Map) {
    throw UpdateManifestException('missing-field', 'artifacts 缺失');
  }
  UpdateArtifact art(String k, {bool requireVersionCode = false}) {
    final a = artifacts[k];
    if (a is! Map) throw UpdateManifestException('missing-field', 'artifacts.$k 缺失');
    const allowed = {'artifactId', 'fileName', 'versionName', 'versionCode', 'sizeBytes', 'sha256'};
    for (final f in a.keys) {
      if (!allowed.contains(f)) throw UpdateManifestException('unknown-field', 'artifacts.$k 未知字段: $f');
    }
    final versionCode = a['versionCode'];
    return UpdateArtifact(
      artifactId: strFieldIn(a, 'artifactId'),
      fileName: strFieldIn(a, 'fileName'),
      versionName: strFieldIn(a, 'versionName'),
      versionCode: requireVersionCode
          ? intFieldIn(a, 'versionCode')
          : (versionCode is int ? versionCode : null),
      sizeBytes: intFieldIn(a, 'sizeBytes'),
      sha256: strFieldIn(a, 'sha256'),
    );
  }

  return UpdateManifest(
    schemaVersion: intField('schemaVersion'),
    sequence: intField('sequence'),
    channel: strField('channel'),
    publishedAt: strField('publishedAt'),
    minPluginVersion: strField('minPluginVersion'),
    minAppVersionCode: intField('minAppVersionCode'),
    minKeyringVersionCode: doc['minKeyringVersionCode'] is int
        ? doc['minKeyringVersionCode'] as int
        : null,
    app: art('app', requireVersionCode: true),
    plugin: art('plugin'),
  );
}

int intFieldIn(Map m, String k) {
  final v = m[k];
  if (v is! int) throw UpdateManifestException('bad-type', '$k 必须是整数');
  return v;
}

String strFieldIn(Map m, String k) {
  final v = m[k];
  if (v is! String) throw UpdateManifestException('bad-type', '$k 必须是字符串');
  return v;
}

/// manifest 的 payloadDigest：SHA-256(JCS(剔除 signatures 后) 的 UTF-8 字节) 的 hex。
/// 用于 sequence 四规则的持久化比对（与签名载荷同源，跨源/重序列化一致）。
Future<String> payloadDigestOf(String raw) async {
  final Object? doc;
  try {
    doc = jsonDecode(raw);
  } catch (e) {
    throw UpdateManifestException('invalid-json', 'manifest 非合法 JSON: $e');
  }
  if (doc is! Map) throw UpdateManifestException('not-object', 'manifest 顶层必须是对象');
  final without = Map<dynamic, dynamic>.of(doc)..remove('signatures');
  final hash = await Sha256().hash(utf8.encode(jcs(without)));
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// sequence 四规则（PRD §5.1.3）。
enum SequenceDecision { rejectOlder, sameAllowed, sameConflict, acceptNew }

SequenceDecision decideSequence({
  required int? storedSequence,
  required String? storedDigest,
  required int sequence,
  required String payloadDigest,
}) {
  if (storedSequence == null || sequence > storedSequence) return SequenceDecision.acceptNew;
  if (sequence < storedSequence) return SequenceDecision.rejectOlder;
  return storedDigest == payloadDigest
      ? SequenceDecision.sameAllowed
      : SequenceDecision.sameConflict;
}
