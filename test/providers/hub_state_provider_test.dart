import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_audio_sync/models/client_info.dart';
import 'package:local_audio_sync/providers/hub_state_provider.dart';

ClientInfo _makeClient(String id, String name) => ClientInfo(
      id: id,
      name: name,
      ip: '192.168.1.10',
      port: 7777,
      lastSeen: DateTime.now(),
    );

void main() {
  group('HubStateNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('initially has no connected clients', () {
      final state = container.read(hubStateProvider);
      expect(state, isEmpty);
    });

    test('addOrUpdateClient appends a client', () {
      final notifier = container.read(hubStateProvider.notifier);
      notifier.addOrUpdateClient(_makeClient('uuid-1', 'Alice'));
      final state = container.read(hubStateProvider);
      expect(state, hasLength(1));
      expect(state['uuid-1']?.name, equals('Alice'));
    });

    test('removeClient removes the correct client', () {
      final notifier = container.read(hubStateProvider.notifier);
      notifier.addOrUpdateClient(_makeClient('uuid-1', 'Alice'));
      notifier.addOrUpdateClient(_makeClient('uuid-2', 'Bob'));
      notifier.removeClient('uuid-1');
      final state = container.read(hubStateProvider);
      expect(state, hasLength(1));
      expect(state.containsKey('uuid-2'), isTrue);
    });

    test('setVolume updates volume for the correct client', () {
      final notifier = container.read(hubStateProvider.notifier);
      notifier.addOrUpdateClient(_makeClient('uuid-1', 'Alice'));
      notifier.setVolume('uuid-1', 0.75);
      final state = container.read(hubStateProvider);
      expect(state['uuid-1']?.volume, closeTo(0.75, 0.001));
    });

    test('setVolume does not affect other clients', () {
      final notifier = container.read(hubStateProvider.notifier);
      notifier.addOrUpdateClient(_makeClient('uuid-1', 'Alice'));
      notifier.addOrUpdateClient(_makeClient('uuid-2', 'Bob'));
      notifier.setVolume('uuid-1', 0.5);
      final state = container.read(hubStateProvider);
      expect(state['uuid-2']?.volume, equals(1.0)); // default volume
    });
  });
}
