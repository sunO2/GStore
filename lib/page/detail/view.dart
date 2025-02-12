import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:gstore/compent/link_text.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'logic.dart';
import 'package:installed_apps/app_info.dart' as sysAppInfo;
import 'package:jovial_svg/jovial_svg.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:gstore/core/core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_html/flutter_html.dart';

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  Widget _flightShuttleBuilder(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    return DefaultTextStyle(
      style: DefaultTextStyle.of(toHeroContext).style,
      child: toHeroContext.widget,
    );
  }

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(DetailLogic());
    final state = Get.find<DetailLogic>().state;
    return Scaffold(
      appBar: AppBar(
        title: Hero(
            flightShuttleBuilder: _flightShuttleBuilder,
            tag: logic.app.name,
            child: Text(
              logic.app.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            )),
        actions: [
          IconButton(
            onPressed: () {},
            icon: SizedBox(
              width: 24,
              height: 24,
              child: ScalableImageWidget(
                si: SvgIcon.history(context),
              ),
            ),
            tooltip: "历史版本",
          ),
          IconButton(
            onPressed: logic.openBrowser,
            icon: SizedBox(
              width: 24,
              height: 24,
              child: ScalableImageWidget(
                si: SvgIcon.browser(context),
              ),
            ),
            tooltip: "仓库浏览",
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onLongPress: () {
                          if (logic.state.release[0] == null) {
                            return;
                          }
                          Get.bottomSheet(
                            persistent: false,
                            Material(
                              borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(16)),
                              child: Markdown(
                                  data: logic.state.release[0]?["body"] ?? ""),
                            ),
                          );
                        },
                        child: Hero(
                          tag: logic.app.icon,
                          child: Image(
                            image: CachedNetworkImageProvider(logic.app.icon),
                            width: 64,
                            height: 64,
                          ),
                        ),
                      ),
                      const SizedBox(
                        width: 16,
                      ),
                      GetX<DetailLogic>(builder: (ctl) {
                        dynamic release = (logic.state.release.isNotEmpty)
                            ? logic.state.release[0] ?? {}
                            : {};
                        return Expanded(
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.start,
                              children: [
                                Text(
                                  release["name"] ?? "",
                                  style:
                                      Theme.of(context).textTheme.headlineSmall,
                                ),
                                const SizedBox(
                                  width: 8,
                                ),
                                installStatus(context, ctl, state.installInfo),
                              ],
                            ),
                            const SizedBox(
                              height: 8,
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppStartedWidget(
                                  icon: const Icon(
                                    Icons.get_app_rounded,
                                    size: 14,
                                  ),
                                  name: "Fork",
                                  flag: "${logic.state.apiInfo().forks}",
                                ),
                                AppStartedWidget(
                                  icon:
                                      const Icon(Icons.star_rounded, size: 14),
                                  name: "Start",
                                  flag:
                                      "${logic.state.apiInfo().stargazers_count}",
                                ),
                              ],
                            )
                          ],
                        ));
                      })
                    ],
                  ),
                  const SizedBox(
                    height: 6,
                  ),
                  Text(logic.app.des),
                  const Divider(
                    height: 18,
                  ),
                  GetX<DetailLogic>(builder: (ctl) {
                    return Text((ctl.state.apiInfo.value.description ?? ""));
                  }),
                  const SizedBox(
                    height: 16,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Download:",
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      GetX<DetailLogic>(builder: (ctl) {
                        dynamic release = (ctl.state.release.isNotEmpty)
                            ? ctl.state.release[0] ?? {}
                            : {};
                        var time = release?["published_at"]?.toString() ?? "";
                        var timeDate =
                            time.isNotEmpty ? DateTime.parse(time) : null;

                        return Text(
                          null != timeDate
                              ? "${timeDate.year}-${timeDate.month}-${timeDate.day}"
                              : "",
                          style: Theme.of(context)
                              .textTheme
                              .bodyLarge
                              ?.copyWith(
                                  fontWeight: FontWeight.w600, fontSize: 10),
                        );
                      }),
                    ],
                  ),
                  const SizedBox(
                    height: 8,
                  ),
                  GetX<DetailLogic>(builder: (cth) {
                    List<dynamic> assets = (logic.state.release.isNotEmpty)
                        ? logic.state.release[0]["assets"] ?? []
                        : [];
                    return (assets.isNotEmpty)
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: assets.map((data) {
                              return DownloadLink(
                                downloadSize: data["size"],
                                downloadCount: data["download_count"],
                                text: data["name"],
                                url: data["browser_download_url"],
                                onLinkTap: (url) {
                                  logic.startDownload(
                                      url,
                                      logic.state.release[0]["tag_name"] ?? "",
                                      data["name"],
                                      downloadSize: data["size"]);
                                },
                                onLongPress: (url) {
                                  Get.defaultDialog(
                                    title: "下载二维码",
                                    content: Container(
                                      width: 120,
                                      height: 120,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        shape: BoxShape.rectangle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withAlpha(100),
                                            offset: const Offset(0, 0),
                                            blurRadius: 24,
                                            spreadRadius: 0,
                                          ),
                                        ],
                                      ),
                                      // color: Colors.white,
                                      child: QrImageView(
                                        data: "${getProxy()}${url ?? ""}",
                                        version: QrVersions.auto,
                                        size: 120,
                                        embeddedImage:
                                            CachedNetworkImageProvider(
                                                logic.app.icon),
                                      ),
                                    ),
                                  );
                                },
                              );
                            }).toList(),
                          )
                        : const SizedBox();
                  }),
                  const SizedBox(
                    height: 16,
                  ),
                ],
              ),
            ),
            GetX<DetailLogic>(
                builder: (ctl) => MarkdownBody(
                      imageDirectory: state.sourceUrl,
                      data: state.body(),
                      onTapLink: logic.onTapLink,
                      builders: <String, MarkdownElementBuilder>{
                        'a': CustomLinkBuilder(),
                      },
                      imageBuilder: (Uri uri, String? title, String? alt) {
                        if (!"$uri".endsWith(".png") &&
                            !"$uri".endsWith(".jpg")) {
                          return Padding(
                            padding: const EdgeInsets.only(
                                left: 2, right: 2, top: 2, bottom: 2),
                            child: ScalableImageWidget.fromSISource(
                              scale: 0.8,
                              si: ScalableImageSource.fromSvgHttpUrl(
                                  Uri.parse('$uri')),
                            ),
                          );
                        } else {
                          var url = "";
                          if ("$uri".startsWith("http")) {
                            url = "${getProxy()}$uri";
                          } else {
                            url = "${state.sourceUrl}$uri";
                          }
                          return Image(
                            image: CachedNetworkImageProvider(url),
                          );
                        }
                      },
                    ))
          ],
        ),
      ),
      floatingActionButton: StreamBuilder<DownloadStatus>(
          stream: logic.counterController.stream,
          builder: (context, status) {
            var data = status.data;
            return status.hasData
                ? FloatingActionButton(
                    onPressed: null,
                    child: Stack(
                      alignment: AlignmentDirectional.center,
                      children: [
                        CircularProgressIndicator(
                          value: data == null ? 0 : data.count / data.total,
                        ),
                        Text(
                          "${data == null ? "" : ((data.count / data.total) * 100).toInt()}",
                          style: Theme.of(context).textTheme.labelSmall,
                        )
                      ],
                    ),
                  )
                : const SizedBox();
          }),
    );
  }

  Widget installStatus(
      BuildContext context, DetailLogic ctl, sysAppInfo.AppInfo? status) {
    var title = null == status ? "未安装" : "installed ${status.versionName}";
    return GestureDetector(
      onTap: null == status ? null : () => ctl.startApp(status.packageName),
      child: Container(
        margin: const EdgeInsets.only(top: 2, bottom: 2),
        padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade600
              : Colors.grey.shade300,
          borderRadius: const BorderRadius.all(Radius.circular(20)),
        ),
        child: Text(
          title,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class AppStartedWidget extends StatelessWidget {
  final Widget? icon;
  final String? name;
  final String? flag;

  const AppStartedWidget({super.key, this.icon, this.name, this.flag});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.only(left: 8, right: 8, top: 2, bottom: 2),
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          border: Border.all(width: 1.0, color: Colors.grey.shade200),
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade800
              : Colors.grey.shade100,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            icon ??
                const SizedBox(
                  width: 12,
                  height: 12,
                ),
            const SizedBox(
              width: 2,
            ),
            Text(
              name ?? "",
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
            ),
            const SizedBox(
              width: 4,
            ),
            Container(
              margin: const EdgeInsets.only(top: 1, bottom: 1),
              padding:
                  const EdgeInsets.only(left: 4, right: 4, top: 1, bottom: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey.shade600
                    : Colors.grey.shade300,
                borderRadius: const BorderRadius.all(Radius.circular(20)),
              ),
              child: Text(
                flag ?? "",
                style:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
              ),
            )
          ],
        ),
      );
}

// 自定义 MarkdownElementBuilder 来处理 <a> 标签
class CustomLinkBuilder extends MarkdownElementBuilder {
  final pattern = RegExp('<img\\s+[^>]*src=["\']([^"\']+)["\']');
  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return Wrap(
      children: element.children?.map((node) {
            List images = pattern
                .allMatches(element.textContent)
                .map((e) => e.group(1))
                .toList();
            if (images.isNotEmpty) {
              return Image(image: CachedNetworkImageProvider(images[0]));
            } else {
              return Text(
                element.textContent,
                style: preferredStyle,
              );
            }
          }).toList() ??
          [],
    );
  }
}
