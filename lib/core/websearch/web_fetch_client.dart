/// 网页正文抓取（P3-7）
///
/// 策略：
/// 1. 直连目标 URL（手动跟随重定向，逐跳做 SSRF 校验）；
/// 2. HTML 用 `package:html` 去噪（脚本/导航/页脚等）抽正文；
/// 3. 直连失败（403/429/5xx/超时）或正文过短 → 回退 `r.jina.ai`（免 key 限速）；
/// 4. 统一截断，避免把上下文撑爆。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'url_guard.dart';
import 'web_search_models.dart';

class WebFetchClient {
  WebFetchClient({
    http.Client? client,
    this.jinaApiKey = '',
    this.timeout = const Duration(seconds: 10),
    this.jinaTimeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String jinaApiKey;
  final Duration timeout;
  final Duration jinaTimeout;
  final http.Client _client;
  final bool _ownsClient;

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36 GStore-Agent';

  Future<WebFetchPage> fetch(String rawUrl, {int maxChars = 8000}) async {
    final uri = UrlGuard.parseHttpUrl(rawUrl);
    await UrlGuard.assertPublicHost(uri);

    String? directText;
    String? directTitle;
    String? publishedAt;
    String? failure;

    try {
      final response = await _getFollowingSafeRedirects(uri);
      if (response.statusCode >= 400) {
        throw WebSearchException(
          'network',
          '直连返回 HTTP ${response.statusCode}',
        );
      }
      final contentType = response.headers['content-type'] ?? '';
      final body = _decodeBody(response);
      if (contentType.contains('html') || body.trimLeft().startsWith('<')) {
        final extracted = _readableText(body);
        directTitle = extracted.title;
        publishedAt = extracted.publishedAt;
        directText = extracted.text;
      } else {
        directText = body.trim();
      }
    } catch (error) {
      if (error is WebSearchException && error.code == 'blocked_url') {
        rethrow; // 内网/非法跳转必须原样上抛，不能降级成"网络失败"
      }
      failure = error is WebSearchException
          ? error.message
          : '直连抓取失败：$error';
      debugPrint('WebFetchClient: $failure');
    }

    // 中文正文 80 字已足够判断"抓到了内容"；过短（SPA 壳/反爬页）才走 Jina
    if (directText != null && directText.length >= 80) {
      return _finish(
        uri: uri,
        title: directTitle,
        text: directText,
        publishedAt: publishedAt,
        via: 'direct',
        maxChars: maxChars,
      );
    }

    // 直连拿到一点内容但过短（SPA/反爬）也走 Jina 兜底
    try {
      final page = await _fetchViaJina(uri, maxChars: maxChars);
      if (page != null) return page;
    } catch (error) {
      debugPrint('WebFetchClient: Jina 兜底失败 - $error');
    }

    if (directText != null && directText.isNotEmpty) {
      return _finish(
        uri: uri,
        title: directTitle,
        text: directText,
        publishedAt: publishedAt,
        via: 'direct',
        maxChars: maxChars,
      );
    }
    throw WebSearchException(
      'network',
      failure ?? '抓取失败：页面没有可读正文',
    );
  }

  /// 手动跟随重定向，每跳都做公网校验。
  Future<http.Response> _getFollowingSafeRedirects(Uri start) async {
    var uri = start;
    for (var hop = 0; hop <= UrlGuard.maxRedirects; hop++) {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': _userAgent,
          'Accept':
              'text/html,application/xhtml+xml,text/plain,application/json;q=0.8,*/*;q=0.5',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7',
        });
      final streamed = await _client.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed);
      final location = response.headers['location'];
      final isRedirect = response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null &&
          location.isNotEmpty;
      if (!isRedirect) return response;
      final next = uri.resolve(location);
      final checked = UrlGuard.parseHttpUrl(next.toString());
      await UrlGuard.assertPublicHost(checked);
      uri = checked;
    }
    throw WebSearchException('network', '重定向次数过多');
  }

  /// 回退方案：Jina Reader（`r.jina.ai`）返回 Markdown。
  Future<WebFetchPage?> _fetchViaJina(Uri uri, {required int maxChars}) async {
    final target = 'https://r.jina.ai/${uri.toString()}';
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Accept': 'text/plain, text/markdown;q=0.9, */*;q=0.5',
      'X-Return-Format': 'markdown',
    };
    final key = jinaApiKey.trim();
    if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';

    final response =
        await _client.get(Uri.parse(target), headers: headers).timeout(jinaTimeout);
    if (response.statusCode != 200) {
      throw WebSearchException(
        'network',
        '正文抓取服务返回 HTTP ${response.statusCode}',
      );
    }
    final raw = _decodeBody(response);
    final parsed = _stripJinaHeader(raw);
    if (parsed.text.trim().length < 12) return null;
    return _finish(
      uri: uri,
      title: parsed.title,
      text: parsed.text,
      publishedAt: parsed.publishedAt,
      via: 'jina',
      maxChars: maxChars,
    );
  }

  static WebFetchPage _finish({
    required Uri uri,
    required String? title,
    required String text,
    required String? publishedAt,
    required String via,
    required int maxChars,
  }) {
    final cleaned = _normalizeWhitespace(text);
    final truncated = cleaned.length > maxChars;
    final content =
        truncated ? '${cleaned.substring(0, maxChars)}…<截断>' : cleaned;
    return WebFetchPage(
      url: uri.toString(),
      title: (title == null || title.trim().isEmpty) ? uri.host : title.trim(),
      content: content,
      publishedAt: publishedAt,
      via: via,
      truncated: truncated,
    );
  }

  static String _decodeBody(http.Response response) {
    final contentType = response.headers['content-type'] ?? '';
    var charset = 'utf-8';
    final match = RegExp(r'charset=([\w-]+)', caseSensitive: false)
        .firstMatch(contentType);
    if (match != null) charset = match.group(1)!.toLowerCase();
    final encoding = Encoding.getByName(charset);
    if (encoding != null && charset != 'utf-8') {
      try {
        return encoding.decode(response.bodyBytes);
      } catch (_) {
        // 落到 UTF-8（容错解码）
      }
    }
    return const Utf8Decoder(allowMalformed: true)
        .convert(response.bodyBytes);
  }

  /// HTML → 正文：去掉脚本/样式/导航/页脚等，块级元素按段落拼接。
  static ({String title, String text, String? publishedAt}) _readableText(
    String html,
  ) {
    final doc = html_parser.parse(html);
    final title = _firstText([
      doc.querySelector('meta[property="og:title"]')?.attributes['content'],
      doc.querySelector('meta[name="twitter:title"]')?.attributes['content'],
      doc.querySelector('title')?.text,
    ]);
    final publishedAt = _firstText([
      doc.querySelector('meta[property="article:published_time"]')
          ?.attributes['content'],
      doc.querySelector('time')?.attributes['datetime'],
    ]);

    for (final selector in const [
      'script',
      'style',
      'noscript',
      'iframe',
      'svg',
      'form',
      'nav',
      'footer',
      'aside',
      'header',
      'button',
      '[role="navigation"]',
      '[aria-hidden="true"]',
    ]) {
      for (final el in doc.querySelectorAll(selector)) {
        el.remove();
      }
    }

    final root = doc.querySelector('article') ??
        doc.querySelector('main') ??
        doc.body ??
        doc.documentElement;
    final blocks = <String>[];
    if (root != null) _collectBlocks(root, blocks);
    var text = blocks.join('\n\n');
    if (text.trim().length < 120) {
      text = doc.body?.text ?? text;
    }
    return (title: title ?? '', text: text, publishedAt: publishedAt);
  }

  static const Set<String> _blockTags = {
    'p', 'div', 'section', 'article', 'li', 'ul', 'ol', 'table', 'tr',
    'blockquote', 'pre', 'code', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br',
    'dd', 'dt', 'figure', 'figcaption',
  };

  static void _collectBlocks(dom.Element element, List<String> out) {
    final tag = element.localName ?? '';
    if (_blockTags.contains(tag)) {
      final text = element.text.trim();
      if (text.isNotEmpty) out.add(text);
      return;
    }
    if (element.nodes.isEmpty) {
      final text = element.text.trim();
      if (text.isNotEmpty) out.add(text);
      return;
    }
    for (final child in element.nodes) {
      if (child is dom.Element) {
        _collectBlocks(child, out);
      } else if (child is dom.Text) {
        final text = child.text.trim();
        if (text.isNotEmpty) out.add(text);
      }
    }
  }

  /// 去掉 Jina 响应头（`Title:` / `URL Source:` / `Markdown Content:`）。
  static ({String? title, String text, String? publishedAt}) _stripJinaHeader(
    String raw,
  ) {
    final lines = raw.split('\n');
    String? title;
    String? publishedAt;
    var start = 0;
    for (var i = 0; i < lines.length && i < 15; i++) {
      final line = lines[i];
      if (line.startsWith('Title:')) {
        title = line.substring(6).trim();
        start = i + 1;
        continue;
      }
      if (line.startsWith('Published Time:')) {
        publishedAt = line.substring(15).trim();
        start = i + 1;
        continue;
      }
      if (line.startsWith('URL Source:') || line.startsWith('Warning:')) {
        start = i + 1;
        continue;
      }
      if (line.startsWith('Markdown Content:')) {
        start = i + 1;
        break;
      }
      if (line.trim().isEmpty) {
        start = i + 1;
        continue;
      }
      break;
    }
    return (
      title: title,
      text: lines.sublist(start).join('\n'),
      publishedAt: publishedAt,
    );
  }

  static String _normalizeWhitespace(String text) {
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
        .toList();
    final out = <String>[];
    var blank = 0;
    for (final line in lines) {
      if (line.isEmpty) {
        blank++;
        if (blank > 1) continue;
      } else {
        blank = 0;
      }
      out.add(line);
    }
    return out.join('\n').trim();
  }

  static String? _firstText(List<String?> candidates) {
    for (final candidate in candidates) {
      final text = candidate?.trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
