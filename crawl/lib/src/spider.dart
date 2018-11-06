import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:canonical_url/canonical_url.dart';
import 'package:engine/engine.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:isolate/load_balancer.dart';
import 'package:isolate/isolate_runner.dart';

Future crawl(
    String entryPoint, List<String> existing, void Function(WebPage) callback,
    {int concurrency}) async {
  concurrency ??= Platform.numberOfProcessors;
  var loadBalancer =
      await LoadBalancer.create(concurrency, IsolateRunner.spawn);
  var crawled = new Set<String>.from(existing);
  var queue = new Queue<String>()..addFirst(entryPoint);
  var recv = new ReceivePort();
  var canonicalizer = new UrlCanonicalizer(removeFragment: true);
  entryPoint = canonicalizer.canonicalize(entryPoint);

  recv.listen((url) {
    if (url is String) {
      var canonical =
          canonicalizer.canonicalize(Uri.parse(url)).replace(query: '');
      var u = canonical.toString().replaceAll(new RegExp(r'\?$'), '');
      const allowedExtensions = const ['', '.html', '.php', '.aspx'];

      if (allowedExtensions.contains(p.extension(u)) && crawled.add(u)) {
        queue.addFirst(u);
      }
    }
  });

  while (queue.isNotEmpty) {
    var data =
        await loadBalancer.run(visitPage, [queue.removeFirst(), recv.sendPort]);
    if (data != null) callback(WebPageSerializer.fromMap(data));
  }
}

final _client = new HttpClient();

String findMeta(html.Document doc, String name) {
  return (doc.head?.querySelector('meta[name="$name"]')?.attributes ??
              <dynamic, String>{})['content']
          ?.trim() ??
      '';
}

Future<Map<String, dynamic>> visitPage(List args) async {
  var page = args[0] as String, sendPort = args[1] as SendPort;
  var currentUri = Uri.parse(page);

  if (!currentUri.hasScheme) currentUri = currentUri.replace(scheme: 'http');

  print('Now crawling $currentUri...');

  HttpClientRequest rq;

  try {
    rq = await _client.openUrl('GET', currentUri);
  } catch (_) {
    // Some failure... Just keep going...
    return null;
  }

  rq.headers
    ..set(HttpHeaders.acceptHeader, ContentType.html.mimeType)
    ..set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)');

  var rs = await rq.close();

  var doc = await rs
      .transform(const Utf8Decoder(allowMalformed: true))
      .join()
      .then(html.parse);

  // Scrape the contents
  var now = new DateTime.now();
  var webPage = new WebPage(
      url: currentUri.toString(),
      contents: Uri.encodeFull(
          (doc.body?.text ?? '').replaceAll(new RegExp(r'\s\s+'), ' ')),
      keywordString: findMeta(doc, 'keywords'),
      author: findMeta(doc, 'author'),
      description: findMeta(doc, 'description'),
      title: doc.head?.querySelector('title')?.text ?? '(untitled)',
      createdAt: now,
      updatedAt: now);

  // We also want to find the pages that this webpage links to.
  var links = doc
      .querySelectorAll('a')
      .where((e) => e.attributes['href']?.trim()?.isNotEmpty == true);

  for (var link in links) {
    var href = Uri.parse(link.attributes['href'].trim());

    // If they are in the same domain.
    if (!href.hasScheme || href.authority == currentUri.authority) {
      href = href.replace(
        path: p.join(currentUri.path, href.path),
      );
    } else {
      // Otherwise, this URL has a scheme, or is just from a different domain.
      if (!href.hasScheme) href = href.replace(scheme: 'http');
    }

    if (!href.hasAuthority) {
      href = href.replace(
          userInfo: currentUri.userInfo,
          host: currentUri.host,
          port: const [80, 443].contains(currentUri.port)
              ? null
              : currentUri.port);
    }

    // Enqueue the crawling of this link.
    sendPort.send(href.toString());
  }

  return webPage.toJson();
}
