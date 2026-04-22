import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ssh_connection.dart';
import '../services/connection_store.dart';
import 'connection_form_page.dart';
import 'terminal_page.dart';

class ConnectionsPage extends StatelessWidget {
  const ConnectionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ConnectionStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('andssh')),
      body: !store.isLoaded
          ? const Center(child: CircularProgressIndicator())
          : store.connections.isEmpty
              ? const _Empty()
              : ListView.separated(
                  itemCount: store.connections.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = store.connections[i];
                    final jump = c.jumpHostId == null
                        ? null
                        : store.byId(c.jumpHostId!);
                    return ListTile(
                      leading: const Icon(Icons.terminal),
                      title: Text(c.name),
                      subtitle: Text(
                        '${c.username}@${c.host}:${c.port}'
                        '${jump == null ? '' : '  (via ${jump.name})'}',
                      ),
                      trailing: PopupMenuButton<_Action>(
                        onSelected: (a) => _handleAction(context, c, a),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _Action.edit,
                            child: Text('Edit'),
                          ),
                          PopupMenuItem(
                            value: _Action.delete,
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TerminalPage(connection: c),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const ConnectionFormPage(),
          ),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    SshConnection c,
    _Action a,
  ) async {
    final store = context.read<ConnectionStore>();
    switch (a) {
      case _Action.edit:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ConnectionFormPage(existing: c),
          ),
        );
        break;
      case _Action.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('Delete ${c.name}?'),
            content: const Text('This removes the saved connection and '
                'its stored credentials from this device.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) await store.delete(c.id);
        break;
    }
  }
}

enum _Action { edit, delete }

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No saved connections yet.\nTap + to add one.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
