import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../presentation/screens/splash/splash_screen.dart';
import '../presentation/screens/onboarding/welcome_screen.dart';
import '../presentation/screens/onboarding/identity_creation_screen.dart';
import '../presentation/screens/onboarding/choose_nickname_screen.dart';
import '../presentation/screens/onboarding/recovery_setup_screen.dart';
import '../presentation/screens/onboarding/app_lock_setup_screen.dart';
import '../presentation/screens/chat_list/chat_list_screen.dart';
import '../presentation/screens/chat/chat_screen.dart';
import '../presentation/screens/calls/voice_call_screen.dart';
import '../presentation/screens/calls/video_call_screen.dart';
import '../presentation/screens/settings/settings_screen.dart';
import '../presentation/screens/profile/profile_screen.dart';
import '../presentation/screens/groups/group_management_screen.dart';
import '../presentation/screens/groups/new_group_screen.dart';
import '../presentation/screens/security/security_center_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (c, s) => const SplashScreen()),
      GoRoute(path: '/onboarding/welcome', builder: (c, s) => const WelcomeScreen()),
      GoRoute(path: '/onboarding/identity', builder: (c, s) => const IdentityCreationScreen()),
      GoRoute(path: '/onboarding/nickname', builder: (c, s) => const ChooseNicknameScreen()),
      GoRoute(path: '/onboarding/recovery', builder: (c, s) => const RecoverySetupScreen()),
      GoRoute(path: '/onboarding/app-lock', builder: (c, s) => const AppLockSetupScreen()),
      GoRoute(path: '/chats', builder: (c, s) => const ChatListScreen()),
      GoRoute(
        path: '/chat/:chatId',
        builder: (c, s) => ChatScreen(chatId: s.pathParameters['chatId']!),
      ),
      GoRoute(
        path: '/call/voice/:chatId',
        builder: (c, s) => VoiceCallScreen(chatId: s.pathParameters['chatId']!),
      ),
      GoRoute(
        path: '/call/video/:chatId',
        builder: (c, s) => VideoCallScreen(chatId: s.pathParameters['chatId']!),
      ),
      GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen()),
      GoRoute(
        path: '/profile/:userId',
        builder: (c, s) => ProfileScreen(userId: s.pathParameters['userId']!),
      ),
      GoRoute(
        path: '/group/:chatId/manage',
        builder: (c, s) => GroupManagementScreen(chatId: s.pathParameters['chatId']!),
      ),
      GoRoute(path: '/group/new', builder: (c, s) => const NewGroupScreen()),
      GoRoute(path: '/security', builder: (c, s) => const SecurityCenterScreen()),
    ],
  );
});
