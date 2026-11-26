import 'package:aer_rdp/main.dart';
import 'package:aer_rdp/src/rust/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('AerRdpApp renders bootstrap shell and engine status', (WidgetTester tester) async {
    const summary = RdpEngineSummary(
      name: 'aer-rdp-core',
      version: '0.1.0',
      supportsRdpsnd: true,
      tlsProvider: 'rustls-ring',
      pcmFormatTag: 1,
    );

    await tester.pumpWidget(
      AerRdpApp(
        engineStatus:
            '${summary.name} v${summary.version} • ${summary.tlsProvider} • rdpsnd=${summary.supportsRdpsnd}',
      ),
    );

    expect(find.text('aer-rdp'), findsWidgets);
    expect(
      find.text('aer-rdp-core v0.1.0 • rustls-ring • rdpsnd=true'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget);
  });
}
