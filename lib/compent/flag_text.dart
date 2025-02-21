import 'package:flutter/material.dart';

class FlagText extends StatelessWidget {
  final String text;

  const FlagText(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
        padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withAlpha(130),
          borderRadius: const BorderRadius.all(Radius.circular(20)),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
        ),
      );
}
