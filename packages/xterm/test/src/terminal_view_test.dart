import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:xterm/xterm.dart';

import '../_fixture/_fixture.dart';

@GenerateNiceMocks([MockSpec<TerminalInputHandler>()])
import 'terminal_view_test.mocks.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('packed updates retain unchanged rows and match a fresh render',
      (tester) async {
    final terminal = Terminal()..resize(12, 4);
    final boundaryKey = GlobalKey();
    Widget view(Key key) => MaterialApp(
          home: RepaintBoundary(
            key: boundaryKey,
            child: TerminalView(terminal,
                key: key, autoResize: false, cursorBlink: false),
          ),
        );
    const viewKey = ValueKey('cached');
    await tester.pumpWidget(view(viewKey));
    final renderer = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final cells = Uint32List(12 * 4 * 5);
    void publish({int cursorColumn = 0}) => terminal.applyPackedScreen(
          packedCells: cells,
          columns: 12,
          rows: 4,
          cursorColumn: cursorColumn,
          cursorRow: 0,
          usingAlternateScreen: false,
        );
    publish();
    await tester.pump();
    var before = renderer.debugRecordedLineCount;
    publish();
    await tester.pump();
    expect(renderer.debugRecordedLineCount, before);

    cells[12 * 5 + 3] = 'X'.codeUnitAt(0) | (1 << 22);
    publish();
    await tester.pump();
    expect(renderer.debugRecordedLineCount - before, 1);

    before = renderer.debugRecordedLineCount;
    publish(cursorColumn: 3);
    await tester.pump();
    expect(renderer.debugRecordedLineCount, before);

    // Color/style-only changes also invalidate the retained picture.
    cells[12 * 5] = (1 << 25) | 2;
    publish();
    await tester.pump();
    expect(renderer.debugRecordedLineCount - before, 1);

    Future<Uint8List> pixels() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return Uint8List.fromList(bytes!.buffer.asUint8List());
    }

    // Clear the old glyph, update another row, and move the cursor without
    // painting between publications. A retained picture must not survive it.
    cells[12 * 5 + 3] = 0;
    publish();
    cells[24 * 5 + 3] = 'Y'.codeUnitAt(0) | (1 << 22);
    publish();
    await tester.pump();
    final cached = await tester.runAsync(pixels);
    await tester.pumpWidget(view(const ValueKey('fresh')));
    expect(await tester.runAsync(pixels), orderedEquals(cached!));
  });

  testWidgets(
    'htop golden test',
    (tester) async {
      final terminal = Terminal();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal),
        ),
      ));

      terminal.write(TestFixtures.htop_80x25_3s());
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/htop_80x25_3s.png'),
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'color golden test',
    (tester) async {
      final terminal = Terminal();

      // terminal.lineFeedMode = true;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            textStyle: TerminalStyle(fontSize: 8),
          ),
        ),
      ));

      terminal.write(TestFixtures.colors().replaceAll('\n', '\r\n'));
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/colors.png'),
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'long ASCII history stays aligned while scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(800, 180);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final terminal = Terminal(maxLines: 200);
      final scrollController = ScrollController();
      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          scrollController: scrollController,
        ),
      ));

      terminal.write(List.generate(
        40,
        (index) => 'interface $index: flags=8863<UP,BROADCAST,RUNNING> '
            'inet 192.0.2.$index',
      ).join('\r\n'));
      await tester.pump();
      scrollController.jumpTo(scrollController.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/long_ascii_history_scroll.png'),
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets('scrolling cached history reuses painted rows', (tester) async {
    tester.view.physicalSize = const Size(800, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final terminal = Terminal(maxLines: 200);
    final scrollController = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: TerminalView(terminal, scrollController: scrollController),
    ));
    terminal.write(List.generate(50, (i) => 'history row $i').join('\r\n'));
    await tester.pump();
    scrollController.jumpTo(scrollController.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();

    final renderer = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    final painted = renderer.debugPaintedLineCount;
    final recorded = renderer.debugRecordedLineCount;
    expect(recorded, greaterThan(0));

    scrollController.jumpTo(scrollController.offset + 1);
    await tester.pump();
    expect(renderer.debugPaintedLineCount, painted);

    scrollController.jumpTo(scrollController.offset + renderer.lineHeight);
    await tester.pump();
    expect(renderer.debugPaintedLineCount - painted, lessThanOrEqualTo(2));

    final beforeTheme = renderer.debugRecordedLineCount;
    await tester.pumpWidget(MaterialApp(
      home: TerminalView(
        terminal,
        scrollController: scrollController,
        theme: TerminalThemes.whiteOnBlack,
      ),
    ));
    expect(renderer.debugRecordedLineCount, greaterThan(beforeTheme));

    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final beforeOutput = renderer.debugRecordedLineCount;
    terminal.write('\rupdated screen row');
    await tester.pump();
    expect(renderer.debugRecordedLineCount, greaterThan(beforeOutput));
  });

  testWidgets('trackpad moves main-buffer history by sub-line deltas',
      (tester) async {
    tester.view.physicalSize = const Size(800, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final terminal = Terminal(maxLines: 200);
    final scrollController = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: TerminalView(terminal, scrollController: scrollController),
    ));
    terminal.write(List.generate(50, (i) => 'history row $i').join('\r\n'));
    await tester.pump();
    scrollController.jumpTo(scrollController.position.maxScrollExtent / 2);
    await tester.pump();

    final renderer = tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
    var caretUpdates = 0;
    renderer.onEditableRect = (_, __) => caretUpdates++;
    await tester.pump();

    final start = scrollController.offset;
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    const position = Offset(100, 100);
    await tester.sendEventToBinding(pointer.panZoomStart(position));
    for (var i = 1; i <= 5; i++) {
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(position, pan: Offset(0, -i.toDouble())),
      );
      await tester.pump();
      expect(scrollController.offset, closeTo(start + i, 0.1));
    }
    expect(caretUpdates, 0);
    renderer.composingText = 'a';
    await tester.pump();
    expect(caretUpdates, 1);
    await tester.sendEventToBinding(pointer.panZoomEnd());
  });

  testWidgets('macOS history scroll hides and restores the text input view',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      tester.view.physicalSize = const Size(800, 180);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final output = <String>[];
      final terminal = Terminal(maxLines: 200, onOutput: output.add);
      final scrollController = ScrollController();
      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          autofocus: true,
          scrollController: scrollController,
        ),
      ));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);

      terminal.write(List.generate(50, (i) => 'history row $i').join('\r\n'));
      await tester.pump();
      scrollController.jumpTo(scrollController.position.maxScrollExtent / 2);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.pump(const Duration(milliseconds: 149));
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.testTextInput.isVisible, isTrue);
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'x',
        selection: TextSelection.collapsed(offset: 1),
      ));
      await tester.pump();
      expect(output, contains('x'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.testTextInput.isVisible, isTrue);

      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ));
      await tester.pump();
      scrollController.jumpTo(scrollController.position.maxScrollExtent / 3);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  group('TerminalView.readOnly', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, readOnly: true, autofocus: true),
        ),
      ));

      // https://github.com/flutter/flutter/issues/11181#issuecomment-314936646
      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      binding.testTextInput.enterText('ls -al');
      await binding.idle();

      expect(terminalOutput.join(), isEmpty);
    });

    testWidgets('does not block input when false', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, readOnly: false, autofocus: true),
        ),
      ));

      // https://github.com/flutter/flutter/issues/11181#issuecomment-314936646
      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      binding.testTextInput.enterText('ls -al');
      await binding.idle();

      expect(terminalOutput.join(), 'ls -al');
    });
  });

  group('TerminalView.focusNode', () {
    testWidgets('is not listened when terminal is disposed', (tester) async {
      final terminal = Terminal();

      final focusNode = FocusNode();

      final isActive = ValueNotifier(true);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: isActive,
            builder: (context, isActive, child) {
              if (!isActive) {
                return Container();
              }
              return TerminalView(
                terminal,
                focusNode: focusNode,
                autofocus: true,
              );
            },
          ),
        ),
      ));

      // ignore: invalid_use_of_protected_member
      expect(focusNode.hasListeners, isTrue);

      isActive.value = false;
      await tester.pumpAndSettle();

      // ignore: invalid_use_of_protected_member
      expect(focusNode.hasListeners, isFalse);
    });

    testWidgets('does not dispose external focus node', (tester) async {
      final terminal = Terminal();

      final focusNode = FocusNode();

      final isActive = ValueNotifier(true);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: isActive,
            builder: (context, isActive, child) {
              if (!isActive) {
                return Container();
              }
              return TerminalView(
                terminal,
                focusNode: focusNode,
                autofocus: true,
              );
            },
          ),
        ),
      ));

      isActive.value = false;
      await tester.pumpAndSettle();

      expect(() => focusNode.addListener(() {}), returnsNormally);
    });

    testWidgets(
      'syncAfterShown re-sends resize even when viewport size is unchanged',
      (tester) async {
        final resizeEvents =
            <(int width, int height, int pixelWidth, int pixelHeight)>[];
        final terminal = Terminal()
          ..onResize = (width, height, pixelWidth, pixelHeight) {
            resizeEvents.add((width, height, pixelWidth, pixelHeight));
          };

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: TerminalView(
                  terminal,
                  hardwareKeyboardOnly: true,
                ),
              ),
            ),
          ),
        );

        expect(resizeEvents, isNotEmpty);
        resizeEvents.clear();

        final state =
            tester.state<TerminalViewState>(find.byType(TerminalView));
        state.syncAfterShown();
        await tester.pump();
        await tester.pump();

        expect(
          resizeEvents,
          isNotEmpty,
          reason:
              're-shown terminals need to push the current viewport size to newly attached sessions',
        );
        expect(
          resizeEvents.single.$1,
          terminal.viewWidth,
        );
        expect(
          resizeEvents.single.$2,
          terminal.viewHeight,
        );
      },
    );
  });

  group('TerminalController.pointerInputs', () {
    testWidgets('works', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(Offset(1, 1)));

      await tester.pumpAndSettle();

      expect(output, isNotEmpty);
    });

    testWidgets('does not respond when disabled', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.none(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(Offset(1, 1)));

      await tester.pumpAndSettle();

      expect(output, isEmpty);
    });

    testWidgets('does not send drag motion by default', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1002h\x1b[?1006h');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(const Offset(1, 1)));
      await tester.pump();
      output.clear();

      await tester.sendEventToBinding(pointer.move(const Offset(40, 1)));
      await tester.pump();

      expect(output, isEmpty);
    });

    testWidgets('sends drag motion when enabled', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1002h\x1b[?1006h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(const Offset(1, 1)));
      await tester.pump();
      output.clear();

      await tester.sendEventToBinding(pointer.move(const Offset(40, 1)));
      await tester.pump();

      expect(output.join(), contains('\x1b[<32;'));
    });
  });

  group('TerminalView.autofocus', () {
    testWidgets('works', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              focusNode: focusNode,
            ),
          ),
        ),
      );

      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('works in hardwareKeyboardOnly mode', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              focusNode: focusNode,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      expect(focusNode.hasFocus, isTrue);
    });
  });

  group('TerminalView.hardwareKeyboardOnly', () {
    testWidgets('works', (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);

      expect(output.join(), 'abc');
    });
  });

  group('TerminalView.textScaler', () {
    testWidgets('works', (tester) async {
      final terminal = Terminal();

      final textScaler = ValueNotifier(TextScaler.linear(1.0));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<TextScaler>(
              valueListenable: textScaler,
              builder: (context, textScaler, child) {
                return TerminalView(
                  terminal,
                  textScaler: textScaler,
                );
              },
            ),
          ),
        ),
      );

      terminal.write('Hello World');
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/text_scale_factor@1x.png'),
      );

      textScaler.value = TextScaler.linear(2.0);
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/text_scale_factor@2x.png'),
      );
    });

    testWidgets('can obtain textScaler from parent', (tester) async {
      final terminal = Terminal();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: TerminalView(
                terminal,
              ),
            ),
          ),
        ),
      );

      terminal.write('Hello World');
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/text_scale_factor@2x.png'),
      );
    });
  });

  group('TerminalView.inputHandler', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);

      await tester.pumpAndSettle();

      expect(terminalOutput.join(), '\x04');
    });

    testWidgets('can convert text input to key events', (tester) async {
      final inputHandler = MockTerminalInputHandler();
      when(inputHandler.call(any)).thenAnswer((invocation) => 'AAA');

      final terminalOutput = <String>[];
      final terminal = Terminal(
        inputHandler: inputHandler,
        onOutput: terminalOutput.add,
      );

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      binding.testTextInput.enterText('c');
      await binding.idle();

      await tester.pumpAndSettle();

      verify(inputHandler.call(any));
      expect(terminalOutput.join(), 'AAA');
    });
  });

  group('TerminalView.simulateScroll', () {
    testWidgets('trackpad pan delta is already in logical pixels',
        (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);

      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add)
        ..write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');

      final controller = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          controller: controller,
          textStyle: const TerminalStyle(fontSize: 16, height: 1),
        ),
      ));

      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      const position = Offset(100, 100);
      await tester.sendEventToBinding(pointer.panZoomStart(position));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(position, pan: const Offset(0, -20)),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(terminalOutput, hasLength(1));
      expect(terminalOutput.single, contains('\x1b[<65;'));
    });

    testWidgets('sends basic mouse wheel reporting by default', (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);

      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add)
        ..write('\x1b[?1049h\x1b[?1000h\x1b[?1006h');

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          textStyle: const TerminalStyle(fontSize: 16, height: 1),
        ),
      ));

      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      const position = Offset(100, 100);
      await tester.sendEventToBinding(pointer.panZoomStart(position));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(position, pan: const Offset(0, -20)),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(terminalOutput, hasLength(1));
      expect(terminalOutput.single, contains('\x1b[<65;'));
    });

    testWidgets('sends mouse wheel in drag mouse mode by default',
        (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);

      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add)
        ..write('\x1b[?1049h\x1b[?1002h\x1b[?1006h');

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          textStyle: const TerminalStyle(fontSize: 16, height: 1),
        ),
      ));

      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      const position = Offset(100, 100);
      await tester.sendEventToBinding(pointer.panZoomStart(position));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(position, pan: const Offset(0, -20)),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(terminalOutput, hasLength(1));
      expect(terminalOutput.single, contains('\x1b[<65;'));
    });

    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true, simulateScroll: true),
      ));

      await tester.drag(find.byType(TerminalView), const Offset(0, -100));
      // Scroll keys are flushed after an 8 ms debounce in scroll_handler.
      await tester.pump(const Duration(milliseconds: 16));

      expect(terminalOutput.join(), contains('\x1B[B'));
    });

    testWidgets('trackpad scroll simulates arrow keys without mouse reporting',
        (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          autofocus: true,
          simulateScroll: true,
          textStyle: const TerminalStyle(fontSize: 16, height: 1),
        ),
      ));

      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      const position = Offset(100, 100);
      await tester.sendEventToBinding(pointer.panZoomStart(position));
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(position, pan: const Offset(0, -20)),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(terminalOutput.join(), contains('\x1B[B'));
    });

    testWidgets('does nothing when disabled', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true, simulateScroll: false),
      ));

      await tester.drag(find.byType(TerminalView), const Offset(0, -100));

      expect(terminalOutput.join(), isEmpty);
    });
  });
}
