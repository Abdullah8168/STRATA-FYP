/// ---------------------------------------------------------------
/// EmailJS Configuration (FREE — 200 emails/month)
///
/// 1. Go to https://www.emailjs.com  →  Sign up (free)
/// 2. "Email Services" → "Add New Service" → connect your Gmail
///    → copy the SERVICE ID (e.g. "service_abc123")
/// 3. "Email Templates" → "Create New Template"
///    → Subject: "STRATA — Your verification code"
///    → Body:
///        Hi {{to_name}},
///
///        Your STRATA verification code is: {{otp_code}}
///
///        This code expires in 5 minutes.
///    → Set "To Email" field to: {{to_email}}
///    → Save → copy the TEMPLATE ID (e.g. "template_xyz789")
/// 4. "Account" → "General" tab → copy your PUBLIC KEY
/// 5. Paste all three values below.
/// ---------------------------------------------------------------
class EmailJsConfig {
  // Previous account (blocks non-browser apps, so the Android app can't send):
  //   service_7jf6gwp / template_6u47tg5 / vcmg1MHkTTe8iDN68
  static const String serviceId = 'service_6dcqc6n';
  static const String templateId = 'template_od8qvks';
  static const String publicKey = 'W9CPzwajGCPp-JMHC';
}
