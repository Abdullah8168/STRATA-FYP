import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/constants/emailjs_config.dart';

class EmailOtpService {
  static const _endpoint = 'https://api.emailjs.com/api/v1.0/email/send';

  /// Returns `true` if EmailJS credentials have been configured.
  static bool get isConfigured =>
      EmailJsConfig.serviceId != 'YOUR_SERVICE_ID' &&
      EmailJsConfig.templateId != 'YOUR_TEMPLATE_ID' &&
      EmailJsConfig.publicKey != 'YOUR_PUBLIC_KEY';

  /// Sends [otpCode] to [toEmail] via EmailJS.
  /// Throws on network / API errors.
  static Future<void> sendOtp({
    required String toEmail,
    required String otpCode,
    String toName = 'STRATA User',
  }) async {
    if (!isConfigured) {
      throw Exception(
        'EmailJS is not configured. '
        'Update lib/core/constants/emailjs_config.dart with your credentials.',
      );
    }

    final body = jsonEncode({
      'service_id': EmailJsConfig.serviceId,
      'template_id': EmailJsConfig.templateId,
      'user_id': EmailJsConfig.publicKey,
      'template_params': {
        // Send multiple aliases so different EmailJS templates still receive
        // recipient fields even if variable names differ.
        'to_email': toEmail,
        'email': toEmail,
        'user_email': toEmail,
        'recipient_email': toEmail,
        'to': toEmail,
        'reply_to': toEmail,
        'to_name': toName,
        'name': toName,
        'otp_code': otpCode,
        'otp': otpCode,
        'code': otpCode,
      },
    });

    debugPrint('[STRATA] Sending email OTP to $toEmail via EmailJS...');

    final response = await http.post(
      Uri.parse(_endpoint),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode == 200) {
      debugPrint('[STRATA] Email sent successfully to $toEmail');
    } else {
      debugPrint('[STRATA] EmailJS error ${response.statusCode}: ${response.body}');
      throw Exception(
        'Failed to send email (${response.statusCode}): ${response.body}',
      );
    }
  }
}
