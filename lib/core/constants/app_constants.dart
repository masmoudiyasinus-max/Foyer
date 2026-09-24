class AppConstants {
  // Hive Box Names
  static const String boxSettings = 'intercom_settings';
  static const String boxApprovedMembers = 'approved_members';
  static const String boxTasks = 'family_tasks';
  static const String boxGroceries = 'family_groceries';
  static const String boxInvitations = 'family_invitations';
  static const String boxEvents = 'family_events';
  static const String boxPortfolio = 'family_portfolio';
  static const String boxBlockedMembers = 'blocked_members';
  static const String boxMeals = 'family_meals';

  // Settings Keys
  static const String keyMemberName = 'member_name';
  static const String keyDeviceId = 'device_id';
  static const String keyFamilyCode = 'family_code';
  static const String keyIsOnboarded = 'is_onboarded';
  static const String keyAnnouncementTitle = 'announcement_title';
  static const String keyAnnouncementText = 'announcement_text';
  static const String keyAnnouncementUrl = 'announcement_url';
  static const String keyAnnouncementImagePath = 'announcement_image_path';
  static const String keyLastPurgeDate = 'last_purge_date';
  static const String keyConnectionMode = 'connection_mode';

  // Connection Modes
  static const String modeLan = 'lan';
  static const String modeCloud = 'cloud';

  // Networking & Discovery
  static const String mdnsServiceType = '_intercom-foyer._tcp';
  static const int defaultUdpPort = 54443;
  static const int udpBroadcastPort = 8888;
  static const String defaultStunServer = 'stun:stun.l.google.com:19302';

  // Method Channel
  static const String audioChannelName = 'com.foyer.intercom/audio';
}
