import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('distinguishes cache keys that have the same hash code', () {
    final cache = ParagraphCache(8);
    const style = TextStyle(fontSize: 14);
    final firstKey = _CollidingKey(1);
    final secondKey = _CollidingKey(2);

    final first = cache.performAndCacheLayout(
      'i',
      style,
      TextScaler.noScaling,
      firstKey,
    );
    final second = cache.performAndCacheLayout(
      '✢',
      style,
      TextScaler.noScaling,
      secondKey,
    );

    expect(firstKey.hashCode, secondKey.hashCode);
    expect(cache.getLayoutFromCache(firstKey), same(first));
    expect(cache.getLayoutFromCache(secondKey), same(second));
  });
}

class _CollidingKey {
  const _CollidingKey(this.id);

  final int id;

  @override
  int get hashCode => 1;

  @override
  bool operator ==(Object other) => other is _CollidingKey && other.id == id;
}
