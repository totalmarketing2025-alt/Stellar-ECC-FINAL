import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/stellar_theme.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _cards = [
    _ValueProp(icon: Icons.shield_outlined, title: 'Private', body: 'No phone number required. No permanent servers holding your messages.'),
    _ValueProp(icon: Icons.timer_outlined, title: 'Ephemeral', body: 'Messages disappear automatically — nothing lingers after your chat.'),
    _ValueProp(icon: Icons.flash_on_outlined, title: 'Fast', body: 'A lightweight relay and modern encryption keep things quick and responsive.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: StellarColors.bgPrimary,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: _cards.length,
                itemBuilder: (context, i) => _cards[i],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _cards.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: i == _page ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page ? StellarColors.accentBlue : StellarColors.bgElevated,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => context.go('/onboarding/identity'),
                  child: const Text('Get Started'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueProp extends StatelessWidget {
  const _ValueProp({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: StellarColors.stellarGradient),
            child: Icon(icon, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 24),
          Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: StellarColors.textSecondary)),
        ],
      ),
    );
  }
}
