import 'package:aer_rdp/src/rust/api.dart';
import 'package:aer_rdp/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final summary = getEngineSummary();
  final status =
      '${summary.name} v${summary.version} • ${summary.tlsProvider} • rdpsnd=${summary.supportsRdpsnd}';
  runApp(AerRdpApp(engineStatus: status));
}

class AerRdpApp extends StatelessWidget {
  const AerRdpApp({
    super.key,
    this.engineStatus = 'aer-rdp-core ready',
  });

  final String engineStatus;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'aer-rdp',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B57D0)),
        useMaterial3: true,
      ),
      home: AerRdpBootstrapPage(engineStatus: engineStatus),
    );
  }
}

class AerRdpBootstrapPage extends StatelessWidget {
  const AerRdpBootstrapPage({super.key, required this.engineStatus});

  final String engineStatus;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('aer-rdp')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.desktop_windows_outlined, size: 56),
              const SizedBox(height: 16),
              Text(
                'aer-rdp',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                engineStatus,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
