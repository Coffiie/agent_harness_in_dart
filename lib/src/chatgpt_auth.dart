import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Why signing in with ChatGPT didn't work, in words for the user.
class SignInError implements Exception {
  const SignInError(this.message, {this.code});

  final String message;

  /// OpenAI's error code, like invalid_grant, when it sent one.
  final String? code;

  @override
  String toString() => message;
}

/// A signed-in ChatGPT account: what OpenAI's sign-in gave back, saved so
/// the next run doesn't ask again.
class ChatGptAccount {
  const ChatGptAccount({
    required this.clientId,
    required this.subject,
    required this.idToken,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scopes,
    this.email,
  });

  /// The client id OpenAI issued at the first sign-in (`oaiapp_…`).
  final String clientId;

  /// Who signed in: the ID token's `sub`.
  final String subject;
  final String? email;
  final String idToken;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final List<String> scopes;

  /// Whether the user let the harness use their ChatGPT plan.
  bool get canUsePlan => scopes.contains(ChatGptAuth.planScope);

  Map<String, dynamic> toJson() => {
    'client_id': clientId,
    'subject': subject,
    'email': ?email,
    'id_token': idToken,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'scopes': scopes,
  };

  static ChatGptAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return ChatGptAccount(
        clientId: json['client_id'] as String,
        subject: json['subject'] as String,
        email: json['email'] as String?,
        idToken: json['id_token'] as String,
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        scopes: (json['scopes'] as List).cast<String>(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Signs in with ChatGPT, so the harness's model calls use the user's
/// ChatGPT plan instead of an API key. It follows OpenAI's flow for
/// open-source and local apps
/// (developers.openai.com/siwc/token-sharing-open-source): OAuth with PKCE
/// in the browser, a callback on 127.0.0.1, and tokens that refresh.
///
/// It keeps everything in [file], readable only by the user: the account,
/// the client id OpenAI issued, and this computer's host id.
class ChatGptAuth {
  ChatGptAuth(
    this.file, {
    http.Client? client,
    DateTime Function()? clock,
    Future<void> Function(Uri url)? openBrowser,
    Random? random,
    this.port = 1455,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now,
       _openBrowser = openBrowser ?? _open,
       _random = random ?? Random.secure() {
    _load();
  }

  static const issuer = 'https://auth.openai.com';
  static final authorizeUrl = Uri.parse('$issuer/api/accounts/authorize');
  static final tokenUrl = Uri.parse('$issuer/api/accounts/oauth/token');
  static final discoveryUrl = Uri.parse(
    '$issuer/.well-known/openid-configuration',
  );

  /// The API the tokens are for.
  static const resource = 'https://api.openai.com/v1';

  /// The scope that lets the harness use the ChatGPT plan.
  static const planScope = 'chatgpt.tokens.use.direct';
  static const scopes =
      'openid profile email offline_access resource.invoke $planScope';

  /// The name OpenAI's consent screen shows for the first sign-in.
  static const appName = 'coding_agent_in_dart';

  final File file;

  /// The port the callback listens on, when it's free; another one when not.
  final int port;
  final http.Client _client;
  final DateTime Function() _clock;
  final Future<void> Function(Uri url) _openBrowser;
  final Random _random;

  ChatGptAccount? account;

  // This computer's id for OpenAI, made once and kept: opaque, with nothing
  // about the user in it.
  late String hostId;

  // The client id OpenAI issued, kept after sign-out for the next sign-in.
  String? _clientId;

  // Whether the user has seen that requests use their plan.
  var welcomed = false;

  Future<ChatGptAccount>? _refreshing;

  bool get signedIn => account != null;

  void _load() {
    Map<String, dynamic>? saved;
    try {
      saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      saved = null;
    }
    hostId = saved?['host_id'] as String? ?? 'urn:uuid:${_uuid()}';
    _clientId = saved?['client_id'] as String?;
    welcomed = saved?['welcomed'] == true;
    account = ChatGptAccount.fromJson(saved?['account']);
  }

  /// Writes the file so only the user can read it, all at once: a crash
  /// mid-write leaves the old one.
  Future<void> save() async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'host_id': hostId,
        'client_id': ?(account?.clientId ?? _clientId),
        'welcomed': welcomed,
        'account': ?account?.toJson(),
      }),
    );
    if (!Platform.isWindows) await Process.run('chmod', ['600', temp.path]);
    await temp.rename(file.path);
  }

  /// Signs in in the browser. [onUrl] gets the address first, for when the
  /// browser doesn't open on its own.
  ///
  /// OpenAI can turn down the first code it issues with invalid_grant. Its
  /// docs say to drop that code and sign in again with the client id the
  /// registration issued, so that happens once on its own, and [onRetry]
  /// says why the browser opens again.
  Future<ChatGptAccount> signIn({
    void Function(Uri url)? onUrl,
    void Function()? onRetry,
  }) async {
    try {
      return await _signInOnce(onUrl);
    } on SignInError catch (e) {
      if (e.code != 'invalid_grant' || _clientId == null) rethrow;
      onRetry?.call();
      return _signInOnce(onUrl);
    }
  }

  Future<ChatGptAccount> _signInOnce(void Function(Uri url)? onUrl) async {
    final server = await _listen();
    try {
      final redirect = 'http://127.0.0.1:${server.port}/auth/callback';
      final verifier = _randomText(64);
      final state = _randomText(24);
      final nonce = _randomText(24);
      // a returning sign-in says who, so OpenAI can skip the questions
      final known = account;
      final url = authorizeUrl.replace(
        queryParameters: {
          'client_id': _clientId ?? 'dynamic_agent_client',
          if (_clientId == null) 'agent_name_hint': appName,
          'ext_agent_host_id': hostId,
          'id_token_hint': ?known?.idToken,
          'login_hint': ?known?.email,
          'response_type': 'code',
          'redirect_uri': redirect,
          'scope': scopes,
          'resource': resource,
          'state': state,
          'nonce': nonce,
          'code_challenge_method': 'S256',
          'code_challenge': _challenge(verifier),
        },
      );
      onUrl?.call(url);
      unawaited(_openBrowser(url).catchError((_) {}));

      final callback = await _callback(server, state);
      final clientId = _issuedClientId(callback['client_id']);
      // kept now, so a code exchange that fails doesn't register the app
      // a second time
      if (_clientId == null) {
        _clientId = clientId;
        await save();
      }
      final tokens = await _token({
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': callback['code']!,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'resource': resource,
      });
      final signedIn = _account(tokens, clientId, nonce: nonce);
      if (!signedIn.canUsePlan) {
        throw const SignInError(
          "You signed in, but didn't let the harness use your ChatGPT plan. "
          'Sign in again and allow it.',
        );
      }
      account = signedIn;
      _clientId = clientId;
      await save();
      return signedIn;
    } finally {
      await server.close(force: true);
    }
  }

  /// A token for the next request, refreshed first when it's about to run
  /// out. Refreshes happen one at a time, since each one replaces the
  /// refresh token.
  Future<String> accessToken({bool force = false}) async {
    final current = account;
    if (current == null) {
      throw const SignInError('Not signed in with ChatGPT.');
    }
    final fresh = current.expiresAt.isAfter(
      _clock().add(const Duration(minutes: 1)),
    );
    if (fresh && !force) return current.accessToken;
    return (await (_refreshing ??= _refresh(
      current,
    ).whenComplete(() => _refreshing = null))).accessToken;
  }

  Future<ChatGptAccount> _refresh(ChatGptAccount old) async {
    final Map<String, dynamic> tokens;
    try {
      tokens = await _token({
        'grant_type': 'refresh_token',
        'client_id': old.clientId,
        'refresh_token': old.refreshToken,
        'resource': resource,
      });
    } on SignInError {
      // the refresh token is spent: the user signs in again
      account = null;
      await save();
      rethrow;
    }
    final refreshed = _account(tokens, old.clientId, previous: old);
    account = refreshed;
    await save();
    return refreshed;
  }

  /// Signs out: OpenAI revokes the refresh token, and the file forgets the
  /// account. The client id and host id stay for the next sign-in.
  Future<void> signOut() async {
    final current = account;
    if (current == null) return;
    try {
      final discovery = jsonDecode((await _client.get(discoveryUrl)).body);
      if (discovery['revocation_endpoint'] case final String endpoint) {
        await _client.post(
          Uri.parse(endpoint),
          body: {
            'token': current.refreshToken,
            'token_type_hint': 'refresh_token',
            'client_id': current.clientId,
          },
        );
      }
    } catch (_) {
      // forget it here anyway
    }
    account = null;
    await save();
  }

  // The client id a callback came back with. A first sign-in must bring
  // the one OpenAI issued; a later one may leave it out, and can't bring
  // another, since that would swap this account's registration.
  String _issuedClientId(String? fromCallback) {
    final saved = _clientId;
    if (saved == null) {
      if (fromCallback == null || fromCallback == 'dynamic_agent_client') {
        throw const SignInError(
          "OpenAI didn't finish registering the app: its sign-in came back "
          'without a client id. Sign in again.',
        );
      }
      return fromCallback;
    }
    if (fromCallback != null && fromCallback != saved) {
      throw const SignInError(
        "OpenAI's sign-in came back for a different app registration than "
        'this one. Sign in again.',
      );
    }
    return saved;
  }

  Future<Map<String, dynamic>> _token(Map<String, String> form) async {
    final response = await _client.post(tokenUrl, body: form);
    final Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      throw SignInError('OpenAI answered ${response.statusCode}.');
    }
    if (response.statusCode != 200 || json is! Map<String, dynamic>) {
      // {"error": "invalid_grant", "error_description": "..."}, or the
      // error as an object
      final error = json is Map ? json['error'] : null;
      final code = switch (error) {
        String code => code,
        {'code': String code} => code,
        {'type': String code} => code,
        _ => null,
      };
      final said = switch ((json, error)) {
        ({'error_description': String said}, _) => said,
        (_, {'message': String said}) => said,
        _ => null,
      };
      final why = [?code, if (said != null && said.isNotEmpty) said];
      throw SignInError(
        'OpenAI turned the sign-in down'
        '${why.isEmpty ? '' : ' (${why.join(': ')})'}. Sign in again.',
        code: code,
      );
    }
    return json;
  }

  ChatGptAccount _account(
    Map<String, dynamic> tokens,
    String clientId, {
    String? nonce,
    ChatGptAccount? previous,
  }) {
    final idToken = tokens['id_token'] as String? ?? previous?.idToken;
    if (idToken == null) {
      throw const SignInError("OpenAI's sign-in didn't give an ID token.");
    }
    final claims = _claims(idToken);
    // The token came straight from OpenAI's token endpoint over TLS, so
    // its issuer is checked by the connection; these check it's for us.
    final audience = claims['aud'];
    final forUs =
        audience == clientId ||
        (audience is List && audience.contains(clientId));
    if (claims['iss'] != issuer || !forUs) {
      throw const SignInError("The ID token isn't for this sign-in.");
    }
    if (nonce != null && claims['nonce'] != nonce) {
      throw const SignInError("The ID token doesn't match this sign-in.");
    }
    return ChatGptAccount(
      clientId: clientId,
      subject: claims['sub'] as String? ?? previous?.subject ?? '',
      email: claims['email'] as String? ?? previous?.email,
      idToken: idToken,
      accessToken: tokens['access_token'] as String,
      refreshToken:
          tokens['refresh_token'] as String? ?? previous!.refreshToken,
      expiresAt: _clock().add(
        Duration(seconds: (tokens['expires_in'] as num?)?.toInt() ?? 3600),
      ),
      scopes: switch (tokens['scope']) {
        final String scope => scope.split(' '),
        _ => previous?.scopes ?? const [],
      },
    );
  }

  static Map<String, dynamic> _claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) throw const SignInError('The ID token is broken.');
    try {
      return jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
          )
          as Map<String, dynamic>;
    } catch (_) {
      throw const SignInError('The ID token is broken.');
    }
  }

  // Listens on 127.0.0.1 (never localhost, OpenAI says), on [port] or any
  // free one.
  Future<HttpServer> _listen() async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
  }

  // Waits for the browser to come back to /auth/callback with this
  // attempt's state, and tells the user they can close the tab.
  Future<Map<String, String>> _callback(HttpServer server, String state) async {
    await for (final request in server) {
      if (request.uri.path != '/auth/callback') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      final query = request.uri.queryParameters;
      final ours = query['state'] == state;
      final denied = query['error'];
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><meta charset="utf-8"><title>coding_agent_in_dart'
        '</title><body style="font-family:system-ui;padding:3rem">'
        '<h1>${ours && denied == null ? 'Signed in' : "Didn't sign in"}'
        '</h1><p>You can close this tab and go back to the terminal.</p>',
      );
      await request.response.close();
      if (!ours) continue;
      if (denied != null) {
        throw SignInError(
          denied == 'access_denied'
              ? 'You cancelled the sign-in.'
              : 'The sign-in failed: $denied.',
        );
      }
      if (query['code'] == null) {
        throw const SignInError("OpenAI's sign-in came back without a code.");
      }
      return query;
    }
    throw const SignInError('The sign-in stopped before it finished.');
  }

  String _randomText(int bytes) => base64Url
      .encode([for (var i = 0; i < bytes; i++) _random.nextInt(256)])
      .replaceAll('=', '');

  static String _challenge(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');

  String _uuid() {
    final b = [for (var i = 0; i < 16; i++) _random.nextInt(256)];
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static Future<void> _open(Uri url) async {
    final (command, args) = Platform.isMacOS
        ? ('open', [url.toString()])
        : Platform.isWindows
        ? ('rundll32', ['url.dll,FileProtocolHandler', url.toString()])
        : ('xdg-open', [url.toString()]);
    await Process.run(command, args);
  }
}
