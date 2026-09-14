import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keqdroid/models/hotkey_config.dart';

void main() {
  test('macOS labels preserve the cross-platform stored shortcut', () {
    final binding = HotkeyBinding.fromToken('ctrl+alt+shift+meta+keyT')!;
    expect(binding.labelForPlatform(TargetPlatform.macOS), '⌃ + ⌥ + ⇧ + ⌘ + T');
    expect(
      binding.labelForPlatform(TargetPlatform.windows),
      'Ctrl + Alt + Shift + Win + T',
    );
    expect(binding.toToken(), 'ctrl+alt+shift+meta+keyT');
  });
}
