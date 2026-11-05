import 'package:flutter_test/flutter_test.dart';

import 'package:insta_analyst/main.dart';

void main() {
  testWidgets('shows the Instagram audience dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(const InstaAnalystApp());

    expect(find.text('Your audience, at a glance'), findsOneWidget);
    expect(find.text('Bring your Instagram data in'), findsOneWidget);
    expect(find.text('Import lists'), findsOneWidget);
  });
}
