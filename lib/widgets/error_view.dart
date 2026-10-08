import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/chain_client.dart';
import '../services/host_api_service.dart';
import '../services/wallet_service.dart';
import '../utils/app_exceptions.dart';

/// Consistent fallback UI when a route has nothing meaningful to render.
class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  final bool showCopyDiagnostics;

  const ErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.showCopyDiagnostics = true,
  });

  static ({String headline, String body}) _message(Object e) {
    if (e is HostApiException) {
      switch (e.code) {
        case 'HOST_UNREACHABLE':
          return (
            headline: "Can't reach the host",
            body: e.message,
          );
        case 'NONCE_REPLAY':
          return (
            headline: 'Session already started — try again',
            body: e.message,
          );
        default:
          return (headline: 'Something went wrong', body: e.message);
      }
    }
    if (e is ChainClientException) {
      return (
        headline: 'Blockchain RPC is having issues',
        body: e.reason,
      );
    }
    if (e is WalletSigningException) {
      return (
        headline: "Couldn't sign — check biometrics",
        body: e.reason,
      );
    }
    if (e is ChatroomDisconnectedException) {
      return (
        headline: 'Lost connection to the chat',
        body: e.reason,
      );
    }
    if (e is TimeoutException) {
      return (
        headline: 'That took too long — retry?',
        body: e.message ?? 'The operation timed out.',
      );
    }
    return (
      headline: 'Something went wrong',
      body: e.toString(),
    );
  }

  String _diagnostics(Object e) {
    if (e is HostApiException) {
      return '${e.code}\n${e.message}\nrequest_id: ${e.requestId ?? 'n/a'}';
    }
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    final msg = _message(error);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              msg.headline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              msg.body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.35),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
            if (showCopyDiagnostics) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _diagnostics(error)));
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy diagnostics'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
