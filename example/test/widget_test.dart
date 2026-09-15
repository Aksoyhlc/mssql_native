
import 'package:flutter_test/flutter_test.dart';

import 'package:mssql_native_example/main.dart';

void main() {
  testWidgets('driver example builds', (tester) async {
    await tester.pumpWidget(const DriverExample());
    expect(find.text('Ready'), findsOneWidget);
  });
}

