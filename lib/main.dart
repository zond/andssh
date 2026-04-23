import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/ssh_connection.dart';
import 'screens/connections_page.dart';
import 'screens/terminal_page.dart';
import 'services/connection_store.dart';
import 'services/host_settings_store.dart';
import 'services/notification_service.dart';
import 'services/secret_store.dart';
import 'services/session_manager.dart';
import 'services/ssh_connector.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AndsshApp());
}

class AndsshApp extends StatefulWidget {
  const AndsshApp({super.key});

  @override
  State<AndsshApp> createState() => _AndsshAppState();
}

class _AndsshAppState extends State<AndsshApp> {
  final _navKey = GlobalKey<NavigatorState>();

  late final SecretStore _secretStore;
  late final ConnectionStore _connectionStore;
  late final HostSettingsStore _hostSettings;
  late final SshConnector _connector;
  late final SessionManager _sessions;
  late final NotificationService _notifications;

  @override
  void initState() {
    super.initState();
    _secretStore = SecretStore();
    _connectionStore = ConnectionStore(_secretStore)..load();
    _hostSettings = HostSettingsStore()..load();
    _connector = SshConnector(_connectionStore, _secretStore);
    _sessions = SessionManager(_secretStore, _connector);
    _notifications = NotificationService();
    _notifications.initialize(
      manager: _sessions,
      onOpen: _openConnectionById,
    );
  }

  void _openConnectionById(String id) {
    final conn = _connectionStore.byId(id);
    if (conn == null) return;
    _navKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(connection: conn),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  void dispose() {
    _notifications.dispose();
    _sessions.disconnectAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SecretStore>.value(value: _secretStore),
        ChangeNotifierProvider<ConnectionStore>.value(value: _connectionStore),
        ChangeNotifierProvider<HostSettingsStore>.value(value: _hostSettings),
        Provider<SshConnector>.value(value: _connector),
        ChangeNotifierProvider<SessionManager>.value(value: _sessions),
      ],
      child: MaterialApp(
        title: 'andssh',
        navigatorKey: _navKey,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
        ),
        home: const ConnectionsPage(),
        onGenerateRoute: (settings) {
          // Lets us push a TerminalPage by connection id from outside the
          // tree (e.g. notification tap). Normal in-app nav uses
          // Navigator.push with a MaterialPageRoute directly, same as
          // before.
          if (settings.name == '/terminal') {
            final conn = settings.arguments as SshConnection;
            return MaterialPageRoute<void>(
              builder: (_) => TerminalPage(connection: conn),
              settings: settings,
            );
          }
          return null;
        },
      ),
    );
  }
}
