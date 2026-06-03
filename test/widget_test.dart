import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_client/main.dart';

void main() {
  testWidgets('app shows splash on startup', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const MobileClientApp());

    expect(find.text('正在初始化客户端'), findsOneWidget);
  });
}
