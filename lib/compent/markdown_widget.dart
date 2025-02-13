import 'package:flutter/material.dart';
import 'package:gstore/compent/link_text.dart';
import 'package:html/dom.dart' as dom;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:html/parser.dart' as htmlparser;

typedef OnLinkTap = void Function(String? url);

// 自定义 MarkdownElementBuilder 来处理 <a> 标签
class CustomLinkBuilder extends MarkdownElementBuilder {
  OnLinkTap? onTap;
  CustomLinkBuilder({this.onTap});

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    var url = element.attributes["href"];
    var call = (md.Element element, TextStyle? preferredStyle) {
      if (element.tag == "a") {
        var first = element.children?.first;
        if (first is md.Text) {
          var domFirst = htmlparser.parseFragment(first.text).firstChild;
          if (domFirst is dom.Element) {
            if (domFirst.localName == "img") {
              var uri = domFirst.attributes["src"];
              var href = domFirst.attributes["href"];
              if (!"$uri".endsWith(".png") && !"$uri".endsWith(".jpg")) {
                return (
                  Padding(
                    padding: const EdgeInsets.only(
                        left: 2, right: 2, top: 2, bottom: 2),
                    child: ScalableImageWidget.fromSISource(
                      scale: 0.8,
                      si: ScalableImageSource.fromSvgHttpUrl(Uri.parse('$uri')),
                    ),
                  ),
                  href
                );
              }
              return (
                Image(
                    height: double.parse(domFirst.attributes["height"] ?? "-1"),
                    image: CachedNetworkImageProvider(
                        domFirst.attributes["src"] ?? "")),
                href
              );
            }
          }
        } else if (first is md.Element) {
          switch (first.tag) {
            case "img":
              return (
                Image(
                    width: 100,
                    image: CachedNetworkImageProvider(
                        first.attributes["src"] ?? "")),
                first.attributes["href"]
              );
          }
        }
      }
      return (
        Text(
          element.textContent,
          style: preferredStyle,
        ),
        ""
      );
    }(element, preferredStyle);
    return InkWell(
      onTap: () {
        onTap!(url);
      },
      child: call.$1,
    );
  }
}
