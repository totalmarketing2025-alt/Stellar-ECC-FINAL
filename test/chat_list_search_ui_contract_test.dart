import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final chatListScreen =
      File('lib/presentation/screens/chat_list/chat_list_screen.dart')
          .readAsStringSync();

  test('chat list search starts as an icon and expands from the app bar', () {
    expect(chatListScreen, contains("key: const ValueKey('chat-list-search-toggle')"));
    expect(chatListScreen, contains('Icons.close : Icons.search'));
    expect(chatListScreen, contains("key: const ValueKey('chat-list-search-field')"));
    expect(chatListScreen, contains('autofocus: true'));
    expect(chatListScreen, contains('onChanged: (_) => setState(() {})'));
    expect(chatListScreen, contains('if (_searchExpanded) _searchController.clear()'));
  });

  test('Stellar header gives the sparkle the purple glow color', () {
    expect(chatListScreen, contains("text: '✨️'"));
    expect(chatListScreen, contains('color: StellarColors.accentPurple'));
    expect(chatListScreen, contains('blurRadius: 12'));
  });
}
