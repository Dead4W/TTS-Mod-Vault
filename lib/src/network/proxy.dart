import 'dart:io'
    show
        ConnectionTask,
        HttpClient,
        HttpClientBasicCredentials,
        HttpOverrides,
        InternetAddress,
        InternetAddressType,
        SecurityContext,
        Socket;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:socks5_proxy/socks_client.dart'
    show ProxySettings, SocksTCPClient;

/// Supported proxy protocols.
///
/// - [http]: standard HTTP(S) proxy (CONNECT tunnelling), handled by
///   [HttpClient.findProxy].
/// - [socks5]: SOCKS5 proxy, handled by a custom [HttpClient.connectionFactory]
///   backed by the `socks5_proxy` package.
enum ProxyType {
  http('HTTP'),
  socks5('SOCKS5');

  final String label;
  const ProxyType(this.label);

  static ProxyType fromLabel(String label) => ProxyType.values.firstWhere(
        (t) => t.label == label,
        orElse: () => ProxyType.http,
      );
}

/// Proxy configuration used for all outgoing connections (Steam Workshop,
/// asset CDNs, GitHub update checks, etc.).
class ProxyConfig {
  final bool enabled;
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  const ProxyConfig({
    this.enabled = false,
    this.type = ProxyType.http,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
  });

  /// Whether the proxy should actually be applied to connections.
  bool get isActive => enabled && host.trim().isNotEmpty && port > 0;

  /// Whether proxy authentication credentials were provided.
  bool get hasAuth => username.isNotEmpty;

  /// "host:port" as expected by [HttpClient.findProxy].
  String get hostPort => '${host.trim()}:$port';
}

/// The currently active proxy configuration.
///
/// This is intentionally a mutable top-level holder: the [HttpOverrides]
/// installed via [installGlobalProxyOverrides] reads it lazily on every request
/// (both in `findProxy` and in the `connectionFactory`). That means proxy
/// changes take effect immediately for ALL connections - including
/// [HttpClient]s that were already created and cached (e.g. Dio's internal
/// adapter or Flutter's image loader) - without having to recreate any clients.
ProxyConfig _activeProxyConfig = const ProxyConfig();

/// Resolved SOCKS proxy address. [SocksTCPClient] needs an [InternetAddress]
/// and the connection factory runs synchronously, so the host is resolved
/// ahead of time in [setActiveProxyConfig].
InternetAddress? _socksProxyAddress;

ProxyConfig get activeProxyConfig => _activeProxyConfig;

/// Updates the active proxy configuration.
///
/// For SOCKS5 the proxy host is resolved to an [InternetAddress] here because
/// the connection factory runs synchronously and cannot await DNS lookups.
Future<void> setActiveProxyConfig(ProxyConfig config) async {
  _activeProxyConfig = config;
  _socksProxyAddress = null;

  if (config.isActive && config.type == ProxyType.socks5) {
    final host = config.host.trim();
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      _socksProxyAddress = parsed;
    } else {
      try {
        final addresses = await InternetAddress.lookup(host);
        if (addresses.isNotEmpty) _socksProxyAddress = addresses.first;
      } catch (e) {
        debugPrint('Failed to resolve SOCKS proxy host "$host": $e');
      }
    }
  }
}

/// Installs a global [HttpOverrides] so that EVERY `dart:io` [HttpClient]
/// created anywhere in the app routes through the configured proxy.
///
/// This covers all networking paths in the app because they all sit on top of
/// `dart:io`'s [HttpClient]:
///  - `package:http` (Steam API, BSON/image/GitHub requests) via its IOClient
///  - `package:dio` (asset downloads and URL live-checks) via its IO adapter
///  - Flutter's `Image.network` / `NetworkImage`
///  - any plugin that uses the default [HttpClient]
///
/// Call this once, as early as possible in `main()`, before any request is
/// made.
void installGlobalProxyOverrides() {
  HttpOverrides.global = _ProxyHttpOverrides();
}

class _ProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);

    // HTTP(S) proxy selection. Evaluated live per request so changes apply even
    // to cached clients. When SOCKS is active we force DIRECT here and let the
    // connection factory below fully control routing.
    client.findProxy = (uri) {
      final cfg = _activeProxyConfig;
      if (cfg.isActive && cfg.type == ProxyType.http) {
        return 'PROXY ${cfg.hostPort}';
      }
      return 'DIRECT';
    };

    // Supply credentials when an HTTP proxy responds with 407.
    client.authenticateProxy = (host, port, scheme, realm) {
      final cfg = _activeProxyConfig;
      if (!cfg.isActive || cfg.type != ProxyType.http || !cfg.hasAuth) {
        return Future.value(false);
      }
      client.addProxyCredentials(
        host,
        port,
        realm ?? '',
        HttpClientBasicCredentials(cfg.username, cfg.password),
      );
      return Future.value(true);
    };

    // The connection factory creates the actual socket. Reading the live config
    // here lets SOCKS on/off (and target/credential changes) take effect
    // immediately without recreating clients. For the HTTP proxy and direct
    // cases it reproduces the default behaviour (connect to the proxy chosen by
    // findProxy, or directly to the target).
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final cfg = _activeProxyConfig;
      final socksAddress = _socksProxyAddress;

      if (cfg.isActive &&
          cfg.type == ProxyType.socks5 &&
          socksAddress != null) {
        final proxies = [
          ProxySettings(
            socksAddress,
            cfg.port,
            username: cfg.hasAuth ? cfg.username : null,
            password: cfg.hasAuth ? cfg.password : null,
          ),
        ];

        // Pass the hostname to the SOCKS server for remote DNS resolution
        // (matches the socks5_proxy package's own factory behaviour).
        // Type is inferred as SocksSocket (public but not exported), which
        // exposes secure()/destroy() used below.
        final socketFuture = SocksTCPClient.connect(
          proxies,
          InternetAddress(uri.host, type: InternetAddressType.unix),
          uri.port,
        );

        if (uri.scheme == 'https') {
          final secureFuture = socketFuture.then((s) => s.secure(uri.host));
          return Future.value(ConnectionTask.fromSocket(
            secureFuture,
            () {
              secureFuture.then((s) => s.destroy()).ignore();
            },
          ));
        }

        return Future.value(ConnectionTask.fromSocket(
          socketFuture,
          () {
            socketFuture.then((s) => s.destroy()).ignore();
          },
        ));
      }

      // Direct connection, or to the HTTP proxy chosen by findProxy.
      return Socket.startConnect(proxyHost ?? uri.host, proxyPort ?? uri.port);
    };

    return client;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    final cfg = _activeProxyConfig;
    if (cfg.isActive && cfg.type == ProxyType.http) {
      return 'PROXY ${cfg.hostPort}';
    }
    return 'DIRECT';
  }
}
