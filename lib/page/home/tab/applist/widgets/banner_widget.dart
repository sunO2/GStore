import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';

class BannerWidget extends StatefulWidget {
  final List<dynamic> data;
  final ValueChanged<dynamic> onBannerTap;

  const BannerWidget({
    super.key,
    required this.data,
    required this.onBannerTap,
  });

  @override
  State<BannerWidget> createState() => _BannerWidgetState();
}

class _BannerWidgetState extends State<BannerWidget> {
  late PageController _controller;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    final length = widget.data.length;
    _currentPage = length;
    _controller = PageController(
      viewportFraction: 0.8,
      initialPage: length,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) {
        _controller.animateToPage(
          length,
          duration: Duration.zero,
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final length = widget.data.length;
    if (length == 0) return const SizedBox();

    return SizedBox(
      height: 180,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: length * 3,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
              });

              if (index == 0) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (_controller.hasClients) {
                    _controller.jumpToPage(length);
                  }
                });
              } else if (index == length * 3 - 1) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (_controller.hasClients) {
                    _controller.jumpToPage(length * 2 - 1);
                  }
                });
              }
            },
            itemBuilder: (context, item) {
              var index = item % length;
              return GestureDetector(
                onTap: () => widget.onBannerTap(widget.data[index]),
                child: Padding(
                  padding: AppSpacing.onlyHorizontalSM_verticalLG,
                  child: ClipRRect(
                    borderRadius: AppRadius.allLG,
                    child: CachedNetworkImage(
                      height: 180,
                      fit: BoxFit.fill,
                      imageUrl: widget.data[index]["banner"],
                    ),
                  ),
                ),
              );
            },
          ),
          Positioned(
            bottom: AppSpacing.sm,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                length,
                (index) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentPage % length == index ? 12 : 8,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: _currentPage % length == index
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.primary.withOpacity(0.4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
