import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/connections_page.dart';
import 'services/connection_store.dart';
import 'services/secret_store.dart';
import 'services/ssh_connector.dart';

void main() {
  runApp(const AndsshApp());
}

class AndsshApp extends StatelessWidget {
  const AndsshApp({super.key});

  @override
  Widget build(BuildContext context) {
    final secretStore = SecretStore();
    final connectionStore = ConnectionStore(secretStore)..load();
    final connector = SshConnector(connectionStore, secretStore);

    return MultiProvider(
      providers: [
        Provider<SecretStore>.value(value: secretStore),
        ChangeNotifierProvider<ConnectionStore>.value(value: connectionStore),
        Provider<SshConnector>.value(value: connector),
      ],
      child: MaterialApp(
        title: 'andssh',
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
        ),
        home: const ConnectionsPage(),
      ),
    );
  }
}
