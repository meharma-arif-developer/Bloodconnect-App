/// Feature switches. Everything here is safe for the FREE Firebase plan
/// by default. Only change a value after reading SETUP_AND_CHANGES.md.
class AppConfig {
  AppConfig._();

  /// Email code (OTP) after password login.
  /// Needs the Firebase Blaze plan + Cloud Functions + an email service key.
  static const bool emailOtpEnabled = false;

  /// Real push notifications through Firebase Cloud Functions.
  /// Needs the Firebase Blaze plan. Leave false if you use the free relay below.
  static const bool pushEnabled = false;

  /// FREE push notifications: address of your Cloudflare Worker, e.g.
  /// 'https://bloodconnect-push-relay.YOURNAME.workers.dev'
  /// (see push_relay/README.md). Empty = off.
  static const String pushRelayUrl = '';

  /// True when either push method is configured.
  static bool get pushActive => pushEnabled || pushRelayUrl.isNotEmpty;

  /// Web address of the admin panel (opened from the "Admin Login" link).
  static const String adminPanelUrl = 'https://bloodconnect-life.web.app';

  /// Expanded blood-group matching. Keep false until a medical professional
  /// has approved the table in blood_compatibility.dart.
  static const bool expandedBloodCompatibility = false;
}
