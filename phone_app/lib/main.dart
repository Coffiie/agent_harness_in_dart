import 'package:flutter/material.dart';

import 'link.dart';
import 'sessions_screen.dart';
import 'term.dart';

void main() => runApp(const HarnessPhone());

class HarnessPhone extends StatelessWidget {
  const HarnessPhone({super.key, this.connect = Link.connect});

  /// How the connect screen reaches the TUI. Tests swap it.
  final Future<Link> Function(String address, String code) connect;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'coding_agent_in_dart',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Graphite.background,
      colorScheme: const ColorScheme.dark(
        primary: Graphite.accent,
        onPrimary: Graphite.background,
        surface: Graphite.background,
        onSurface: Graphite.primary,
        outline: Graphite.outline,
        error: Graphite.error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Graphite.background,
        foregroundColor: Graphite.primary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderSide: BorderSide(color: Graphite.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Graphite.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Graphite.accent),
        ),
        labelStyle: TextStyle(color: Graphite.secondary),
        hintStyle: TextStyle(color: Graphite.secondary),
      ),
    ),
    home: ConnectScreen(connect: connect),
  );
}

/// Where the TUI is, and the code /phone showed.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.connect});

  final Future<Link> Function(String address, String code) connect;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  var _connecting = false;
  String? _error;

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _connecting = true;
      _error = null;
    });
    Link link;
    try {
      link = await widget.connect(_address.text, _code.text);
    } catch (_) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error =
              "Couldn't connect. Check the address and the code /phone "
              'shows, and that the phone is on the same Wi-Fi.';
        });
      }
      return;
    }
    if (!mounted) return link.dispose();
    setState(() => _connecting = false);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => SessionsScreen(link: link)));
    link.dispose();
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 32),
          const Term(mood: 'waiting'),
          const SizedBox(height: 20),
          Text(
            'coding_agent_in_dart',
            style: mono.copyWith(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Run /phone in the TUI, then type what it shows.',
            style: mono.copyWith(color: Graphite.secondary),
          ),
          const SizedBox(height: 28),
          TextField(
            key: const Key('address'),
            controller: _address,
            style: mono,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: '192.168.1.2:4545',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('code'),
            controller: _code,
            style: mono.copyWith(letterSpacing: 4),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Code'),
            onSubmitted: (_) => _connecting ? null : _connect(),
          ),
          const SizedBox(height: 22),
          FilledButton(
            key: const Key('connect'),
            onPressed: _connecting ? null : _connect,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              _connecting ? 'Connecting…' : 'Connect',
              style: mono.copyWith(
                color: Graphite.background,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 16),
            Text(error, style: mono.copyWith(color: Graphite.error)),
          ],
        ],
      ),
    ),
  );
}
