import 'dart:typed_data';

import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SSH receive credit is replenished in half-window batches', () async {
    const windowSize = 2 * 1024 * 1024;
    const packetSize = 32 * 1024;
    final sent = <SSHMessage>[];
    final controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: packetSize,
      localInitialWindowSize: windowSize,
      remoteId: 2,
      remoteInitialWindowSize: 0,
      remoteMaximumPacketSize: packetSize,
      sendMessage: sent.add,
    );
    final subscription = controller.channel.stream.listen((_) {});
    addTearDown(subscription.cancel);

    for (var packet = 0; packet < 31; packet++) {
      controller.handleMessage(
        SSH_Message_Channel_Data(
          recipientChannel: 1,
          data: Uint8List(packetSize),
        ),
      );
    }
    expect(sent.whereType<SSH_Message_Channel_Window_Adjust>(), isEmpty);

    controller.handleMessage(
      SSH_Message_Channel_Data(
        recipientChannel: 1,
        data: Uint8List(packetSize),
      ),
    );
    final adjustments = sent.whereType<SSH_Message_Channel_Window_Adjust>();
    expect(adjustments, hasLength(1));
    expect(adjustments.single.bytesToAdd, 1024 * 1024);

    // A 17 MiB flood uses 544 data packets but only 17 window adjustments,
    // rather than one encrypted acknowledgement for every packet.
    for (var packet = 32; packet < 544; packet++) {
      controller.handleMessage(
        SSH_Message_Channel_Data(
          recipientChannel: 1,
          data: Uint8List(packetSize),
        ),
      );
    }
    expect(sent.whereType<SSH_Message_Channel_Window_Adjust>(), hasLength(17));
  });
}
