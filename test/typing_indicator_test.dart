import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stellar_ecc/presentation/widgets/typing_indicator.dart';
import 'package:stellar_ecc/core/theme/stellar_theme.dart';

void main() {
  testWidgets('typing indicator is left aligned and shows four animated dots',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TypingIndicator(label: 'Alex is typing'),
        ),
      ),
    );

    final dots = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
        return false;
      }
      final decoration = widget.decoration as BoxDecoration;
      return decoration.shape == BoxShape.circle &&
          decoration.color == StellarColors.accentPurple;
    });

    expect(find.text('Alex is typing'), findsOneWidget);
    expect(dots, findsNWidgets(4));
    expect(tester.getTopLeft(find.byType(TypingIndicator)).dx, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
