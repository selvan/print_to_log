import 'package:flutter/material.dart';

class Greeting extends StatelessWidget {
  const Greeting({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => debugPrint('tapped'),
      child: const Text('hi'),
    );
  }
}
