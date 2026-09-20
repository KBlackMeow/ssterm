import 'dart:typed_data';

import 'package:dartssh2/src/message/msg_channel.dart';
import 'package:dartssh2/src/sftp/sftp_client.dart';
import 'package:dartssh2/src/ssh_channel.dart';
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SSH receive credit is topped up after every consumed packet', () async {
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

    // Waiting for a half-window drain before replenishing lets the remote
    // sender run out of credit while the adjustment is still one RTT away,
    // stalling it every ~half window (measured ~40% throughput loss versus
    // openssh on a 160 ms link). Credit must therefore be restored as soon
    // as one maximum-sized packet has been consumed.
    controller.handleMessage(
      SSH_Message_Channel_Data(
        recipientChannel: 1,
        data: Uint8List(packetSize),
      ),
    );
    final adjustments = sent.whereType<SSH_Message_Channel_Window_Adjust>();
    expect(adjustments, hasLength(1));
    expect(adjustments.single.bytesToAdd, packetSize);

    // A 17 MiB flood uses 544 data packets and gets one adjustment per
    // packet — one small control packet per ~32 KiB of data, but the
    // receiver's advertised window never drops below one packet of credit,
    // so the sender never has to idle waiting for a refill.
    for (var packet = 1; packet < 544; packet++) {
      controller.handleMessage(
        SSH_Message_Channel_Data(
          recipientChannel: 1,
          data: Uint8List(packetSize),
        ),
      );
    }
    expect(sent.whereType<SSH_Message_Channel_Window_Adjust>(), hasLength(544));
  });

  test('closing an SFTP client destroys its SSH channel', () async {
    const packetSize = 32 * 1024;
    final controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: packetSize,
      localInitialWindowSize: 2 * 1024 * 1024,
      remoteId: 2,
      remoteInitialWindowSize: 2 * 1024 * 1024,
      remoteMaximumPacketSize: packetSize,
      sendMessage: (_) {},
    );
    final client = SftpClient(controller.channel);

    client.close();
    client.close(); // teardown is intentionally idempotent

    await expectLater(controller.channel.done, completes);
  });
}
