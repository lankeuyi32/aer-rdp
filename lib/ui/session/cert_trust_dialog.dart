import 'package:material_ui/material_ui.dart';

import '../../models/session_models.dart';
import '../aer_keys.dart';

class CertTrustDialog extends StatelessWidget {
  const CertTrustDialog({
    super.key,
    required this.host,
    required this.port,
    required this.cert,
    required this.onDecision,
  });

  final String host;
  final int port;
  final CertInfo cert;
  final ValueChanged<CertTrustDecision> onDecision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: AerKeys.certTrustDialog,
      title: Text(
        cert.isMismatch
            ? 'Certificate Mismatch Warning'
            : 'Verify Server Certificate',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (cert.isMismatch) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'WARNING: Server certificate fingerprint changed! '
                    'Expected ${cert.expectedSha256Hex}',
                    style: TextStyle(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Text('Endpoint: $host:$port'),
              if (cert.subjectCn != null && cert.subjectCn!.isNotEmpty)
                Text('Subject: ${cert.subjectCn}'),
              if (cert.issuer.isNotEmpty) Text('Issuer: ${cert.issuer}'),
              const SizedBox(height: 8),
              const Text(
                'SHA-256 Fingerprint:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              SelectableText(
                cert.sha256Hex,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            OutlinedButton(
              key: AerKeys.certReject,
              onPressed: () => onDecision(CertTrustDecision.reject),
              child: const Text('Reject'),
            ),
            TextButton(
              key: AerKeys.certTrustOnce,
              onPressed: () => onDecision(CertTrustDecision.trustOnce),
              child: const Text('Trust Once'),
            ),
            FilledButton(
              key: AerKeys.certTrustAlways,
              onPressed: () => onDecision(CertTrustDecision.trustAlways),
              child: const Text('Always Trust'),
            ),
          ],
        ),
      ],
    );
  }
}
