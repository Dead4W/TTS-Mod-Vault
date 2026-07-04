import 'dart:convert' show json;

import 'package:flutter/material.dart' show debugPrint;
import 'package:hooks_riverpod/hooks_riverpod.dart' show Ref, StateNotifier;
import 'package:tts_mod_vault/src/network/proxy.dart'
    show ProxyConfig, setActiveProxyConfig;
import 'package:tts_mod_vault/src/state/provider.dart' show storageProvider;
import 'package:tts_mod_vault/src/state/settings/settings_state.dart'
    show SettingsState;

class SettingsNotifier extends StateNotifier<SettingsState> {
  final Ref ref;

  SettingsNotifier(this.ref) : super(SettingsState.defaultState());

  Future<void> initializeSettings() async {
    final settingsJson = ref.read(storageProvider).getSettings();

    SettingsState newState = SettingsState.defaultState();

    if (settingsJson != null) {
      try {
        newState = SettingsState.fromJson(settingsJson);
        debugPrint('Loaded settings from json');
      } catch (e) {
        debugPrint('Failed to load settings from json: $e');
        newState = SettingsState.defaultState();
      }
    }

    debugPrint('initializeSettings - ${json.encode(newState.toJson())}');
    saveSettings(newState);
  }

  Future<void> saveSettings(SettingsState newState) async {
    state = newState;
    await _applyProxyConfig(newState);
    await ref.read(storageProvider).saveSettings(newState);
  }

  /// Pushes the proxy settings into the global HttpOverrides so that all
  /// connections immediately start using (or stop using) the proxy.
  Future<void> _applyProxyConfig(SettingsState newState) async {
    await setActiveProxyConfig(ProxyConfig(
      enabled: newState.proxyEnabled,
      type: newState.proxyType,
      host: newState.proxyHost,
      port: newState.proxyPort,
      username: newState.proxyUsername,
      password: newState.proxyPassword,
    ));
  }

  Future<void> resetToDefaultSettings() async {
    await saveSettings(SettingsState.defaultState());
  }
}
