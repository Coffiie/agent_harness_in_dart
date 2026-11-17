import 'package:flutter/material.dart';

import 'chat_screen.dart';
import 'link.dart';
import 'term.dart';

/// Every session on the computer, like the TUI's sidebar.
class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key, required this.link});

  final Link link;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: link,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text('Sessions', style: mono.copyWith(fontSize: 18)),
      ),
      body: Column(
        children: [
          if (link.closed) const Disconnected(),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: link.sessions.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: Graphite.surface),
              itemBuilder: (context, i) {
                final session = link.sessions[i];
                return ListTile(
                  key: Key('session ${session.id}'),
                  leading: SizedBox(
                    width: 30,
                    child: MiniTerm(mood: session.mood, size: 16),
                  ),
                  title: Text(session.name, style: mono),
                  subtitle: Text(
                    [
                      session.status,
                      ?session.progress,
                      ?session.spent,
                    ].join(' · '),
                    style: mono.copyWith(
                      color: session.status == 'needs you'
                          ? Graphite.accent
                          : Graphite.secondary,
                      fontSize: 12,
                    ),
                  ),
                  trailing: Icon(Icons.chevron_right, color: Graphite.outline),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatScreen(link: link, id: session.id),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// Shown when the TUI went away.
class Disconnected extends StatelessWidget {
  const Disconnected({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Graphite.removed,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Text(
      'Disconnected. Run /phone in the TUI again to reconnect.',
      style: mono.copyWith(color: Graphite.error, fontSize: 12),
    ),
  );
}
