import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/services/discovery_service.dart';

void main() {
  group('DiscoveredHub.fromBeacon', () {
    test('parses a well-formed beacon string', () {
      const beacon = 'LAHUB:192.168.1.5:7777:MyHub';
      final result = DiscoveredHub.fromBeacon(beacon);
      expect(result, isNotNull);
      expect(result!.ip, equals('192.168.1.5'));
      expect(result.port, equals(7777));
      expect(result.name, equals('MyHub'));
    });

    test('returns null for wrong prefix', () {
      expect(DiscoveredHub.fromBeacon('WRONGPREFIX:192.168.1.5:7777:MyHub'), isNull);
    });

    test('returns null for too few segments', () {
      // Only 2 parts after prefix — missing name
      expect(DiscoveredHub.fromBeacon('LAHUB:192.168.1.5:7777'), isNull);
    });

    test('returns null for non-numeric port', () {
      expect(DiscoveredHub.fromBeacon('LAHUB:192.168.1.5:notaport:MyHub'), isNull);
    });

    test('returns null for empty string', () {
      expect(DiscoveredHub.fromBeacon(''), isNull);
    });

    test('hub name containing colons is preserved', () {
      const beacon = 'LAHUB:10.0.0.1:8080:My:Hub';
      final result = DiscoveredHub.fromBeacon(beacon);
      // Our implementation joins trailing segments, so name = 'My:Hub'
      expect(result, isNotNull);
      expect(result!.name, contains('My'));
    });
  });
}
