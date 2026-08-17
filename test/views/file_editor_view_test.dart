// dartssh2 does not export its transport internals, so reach in for
// SSHChannelController to stand up a silent fake SftpClient. Test-only.
import 'package:dartssh2/dartssh2.dart' show SftpClient;
import 'package:dartssh2/src/ssh_channel.dart' show SSHChannelController;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/views/file_editor_view.dart';

/// Editor-internal helper: the EditableText that owns the caret.
EditableText _editable(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText));

/// Editor-internal helper: the text field's own vertical scroll position.
ScrollPosition _editorScroll(WidgetTester tester) =>
    _editable(tester).scrollController!.position;

/// Editor-internal helper: the outer horizontal scroll view that carries
/// the field's horizontal axis (the field's own controller only scrolls
/// vertically).
ScrollPosition _hScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
    )
    .controller!
    .position;

/// Whether any physics in [physics]'s parent chain is a
/// [BouncingScrollPhysics] — i.e. whether a scrollable using it would
/// rubber-band at the edges (macOS's default) instead of clamping.
bool _containsBouncing(ScrollPhysics physics) {
  ScrollPhysics? p = physics;
  while (p != null) {
    if (p is BouncingScrollPhysics) return true;
    p = p.parent;
  }
  return false;
}

/// A live-but-silent [SftpClient]: enough of a transport that
/// [FileEditorView] can be constructed (the widget only touches the
/// client when the user actually saves/reloads), without any network.
SftpClient _fakeSftpClient() {
  final controller = SSHChannelController(
    localId: 1,
    localMaximumPacketSize: 32768,
    localInitialWindowSize: 2097152,
    remoteId: 1,
    remoteInitialWindowSize: 2097152,
    remoteMaximumPacketSize: 32768,
    sendMessage: (_) {},
  );
  return SftpClient(controller.channel);
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required String content,
  TargetPlatform? platform,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: platform != null ? ThemeData(platform: platform) : null,
      home: Scaffold(
        body: FileEditorView(
          path: '/home/user/notes.txt',
          sftp: _fakeSftpClient(),
          label: 'test-host',
          initialContent: content,
          initialMtime: null,
          dirty: ValueNotifier<bool>(false),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('FileEditorView scrolling', () {
    testWidgets(
      'CodeField expands and is not wrapped in an outer scroll view',
      (tester) async {
        await _pumpEditor(tester, content: 'line one\nline two\n');

        final codeField = tester.widget<CodeField>(find.byType(CodeField));
        expect(codeField.expands, isTrue);

        // Regression: the editor used to wrap CodeField in a
        // SingleChildScrollView with expands:false. That made the inner
        // text field grow to full content height, so drag-selecting
        // across lines could never auto-scroll the viewport to follow
        // the selection. The editor must own its own vertical scroll.
        expect(
          find.ancestor(
            of: find.byType(CodeField),
            matching: find.byType(SingleChildScrollView),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the editor text field is internally scrollable for a long file',
      (tester) async {
        final content = List.generate(300, (i) => 'line $i').join('\n');
        await _pumpEditor(tester, content: content);

        final scroll = _editorScroll(tester);

        // The field's own scroll controller carries the vertical extent.
        // This is the prerequisite for auto-scrolling while dragging a
        // selection past the bottom edge — under the old expands:false +
        // outer SingleChildScrollView arrangement this extent was always
        // 0 (the outer scroll view held it all), so the selection could
        // never pull the viewport.
        expect(scroll.maxScrollExtent, greaterThan(0));
      },
    );

    testWidgets(
      'pressing Enter at the end of a line flush with the bottom edge '
      'keeps the caret on-screen',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 400));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final content = List.generate(60, (i) => 'line $i').join('\n');
        await _pumpEditor(tester, content: content);

        final controller = tester
            .widget<CodeField>(find.byType(CodeField))
            .controller;
        final editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        final scroll = _editorScroll(tester);

        // Focus the editor and park the caret at the end of line 24,
        // mid-buffer.
        editable.requestKeyboard();
        await tester.pump();
        final line24end = content.indexOf('line 24') + 'line 24'.length;
        controller.selection = TextSelection.collapsed(offset: line24end);
        await tester.pump();

        // Scroll the field so that line sits flush against the bottom edge
        // of the viewport — the classic spot where Enter used to lose the
        // caret.
        final caretBottom = editable.renderEditable
            .getLocalRectForCaret(TextPosition(offset: line24end))
            .bottom;
        scroll.jumpTo(caretBottom - scroll.viewportDimension);
        await tester.pump();
        final beforePixels = scroll.pixels;

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        // Regression: flutter_code_editor inserts the newline
        // programmatically (its EnterKeyAction routes through
        // CodeController.insertStr), and EditableText deliberately does
        // NOT scroll for programmatic text changes — so Enter used to
        // leave the caret just off-screen below with the viewport pinned.
        // The editor now scrolls the caret back into view itself.
        final afterCaret = editable.renderEditable.getLocalRectForCaret(
          TextPosition(offset: controller.selection.extentOffset),
        );
        expect(scroll.pixels, greaterThan(beforePixels));
        expect(afterCaret.top, greaterThanOrEqualTo(0));
        expect(afterCaret.bottom, lessThanOrEqualTo(scroll.viewportDimension));
      },
    );

    testWidgets(
      'pressing Enter at the end of a long scrolled line keeps the caret '
      'on-screen horizontally',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 400));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // Line 0 is long enough to force the field's horizontal axis far
        // beyond the viewport; lines after it are short.
        final content =
            '${'L' * 200}\n'
            '${List.generate(40, (i) => 'line $i').join('\n')}';
        await _pumpEditor(tester, content: content);

        final controller = tester
            .widget<CodeField>(find.byType(CodeField))
            .controller;
        final editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        final hScroll = _hScroll(tester);

        // Focus and park the caret at the end of the long line.
        editable.requestKeyboard();
        await tester.pump();
        final line0end = content.indexOf('\n');
        controller.selection = TextSelection.collapsed(offset: line0end);
        await tester.pump();

        // Scroll the horizontal axis to the far right so the caret at the
        // end of the long line is pinned to the right edge of the viewport.
        final caretAtLineEnd = editable.renderEditable.getLocalRectForCaret(
          TextPosition(offset: line0end),
        );
        hScroll.jumpTo(caretAtLineEnd.right - hScroll.viewportDimension);
        await tester.pump();
        final beforeH = hScroll.pixels;
        // Sanity: the test scenario really has the caret scrolled out of
        // view to the right edge.
        expect(beforeH, greaterThan(0));

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();

        // Regression: Enter moves the caret to column 0 of the next line,
        // but the horizontal scroll used to stay pinned at the far right —
        // leaving the caret ~one screen-width off-screen to the left.
        // The editor now scrolls the horizontal axis back so the caret is
        // visible again.
        final afterCaret = editable.renderEditable.getLocalRectForCaret(
          TextPosition(offset: controller.selection.extentOffset),
        );
        expect(hScroll.pixels, lessThan(beforeH));
        expect(afterCaret.left, greaterThanOrEqualTo(hScroll.pixels - 1));
        expect(
          afterCaret.right,
          lessThanOrEqualTo(hScroll.pixels + hScroll.viewportDimension + 1),
        );
      },
    );

    testWidgets(
      'the editor scrollables use clamping physics — no rubber-band '
      'overscroll',
      (tester) async {
        // macOS is where the bounce actually shows: Material's scroll
        // behavior defaults every scrollable on that platform to
        // BouncingScrollPhysics. Force the theme platform so the test
        // guards the real platform behavior (widget tests otherwise run as
        // android, which already clamps).
        await _pumpEditor(
          tester,
          content: 'line one\nline two\n',
          platform: TargetPlatform.macOS,
        );

        // Both the outer horizontal axis and the field's own vertical axis
        // are Scrollables under the CodeField — neither may rubber-band.
        final scrollables = tester.widgetList<Scrollable>(
          find.descendant(
            of: find.byType(CodeField),
            matching: find.byType(Scrollable),
          ),
        );
        expect(scrollables, isNotEmpty);
        for (final scrollable in scrollables) {
          expect(
            _containsBouncing(scrollable.controller!.position.physics),
            isFalse,
            reason: 'editor scrollables must clamp, not rubber-band, '
                'even on macOS',
          );
        }
      },
    );
  });
}
