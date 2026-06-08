import 'package:flutter_test/flutter_test.dart';
import 'package:ssterm/services/web_search_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BraveSearchResult.tryParse', () {
    test('parses a well-formed entry', () {
      final r = BraveSearchResult.tryParse({
        'title': 'Example Domain',
        'url': 'https://example.com',
        'description': 'An <strong>example</strong> page',
        'age': '2 weeks ago',
      });
      expect(r, isNotNull);
      expect(r!.title, equals('Example Domain'));
      expect(r.url, equals('https://example.com'));
      // <strong> highlight tags MUST be stripped — they're SERP-render
      // noise that wastes LLM tokens.
      expect(r.description, equals('An example page'));
      expect(r.age, equals('2 weeks ago'));
    });

    test('decodes HTML entities inside descriptions', () {
      final r = BraveSearchResult.tryParse({
        'title': 'AT&amp;T docs',
        'url': 'https://example.com',
        'description': 'Use &lt;script&gt; tags &amp; classes',
      });
      // Title isn't entity-decoded today (Brave returns plain text in
      // most cases); only description is.  That's deliberate — keeps
      // the parser narrow and predictable.
      expect(r!.description,
          equals('Use <script> tags & classes'));
    });

    test('returns null when title is missing', () {
      // Without a title the LLM line ("1. <title>") is useless.
      final r = BraveSearchResult.tryParse({
        'url': 'https://example.com',
        'description': 'noisy',
      });
      expect(r, isNull);
    });

    test('returns null when url is missing', () {
      final r = BraveSearchResult.tryParse({
        'title': 'No URL',
        'description': 'cannot cite',
      });
      expect(r, isNull);
    });

    test('returns null when description is empty', () {
      final r = BraveSearchResult.tryParse({
        'title': 'Bare URL',
        'url': 'https://example.com',
        'description': '',
      });
      expect(r, isNull);
    });

    test('returns null on non-Map input', () {
      // Defence against malformed upstream JSON (an array slipped into
      // results[], a null entry, …).
      expect(BraveSearchResult.tryParse(null), isNull);
      expect(BraveSearchResult.tryParse('not a map'), isNull);
      expect(BraveSearchResult.tryParse(42), isNull);
    });

    test('age field becomes null when empty', () {
      final r = BraveSearchResult.tryParse({
        'title': 't',
        'url': 'https://x',
        'description': 'd',
        'age': '   ',
      });
      expect(r!.age, isNull);
    });
  });

  group('WebSearchService.formatForLlm', () {
    test('renders the standard envelope header', () {
      final out = WebSearchService.formatForLlm(
        'flutter docs',
        const [
          BraveSearchResult(
            title: 'Flutter Documentation',
            url: 'https://docs.flutter.dev',
            description: 'Official Flutter docs',
          ),
        ],
      );
      // Envelope header must match what the system prompt advertises —
      // otherwise the model is looking for the wrong cue.
      expect(out, contains('[Web search results]'));
      expect(out, contains('query: "flutter docs"'));
      expect(out, contains('(1 results)'));
    });

    test('numbers results starting from 1 so the model can cite them', () {
      final out = WebSearchService.formatForLlm(
        'q',
        const [
          BraveSearchResult(
              title: 'A', url: 'https://a', description: 'first'),
          BraveSearchResult(
              title: 'B', url: 'https://b', description: 'second'),
        ],
      );
      // Order matters: 1 before 2, both visible.
      expect(out.indexOf('1. A'), greaterThanOrEqualTo(0));
      expect(out.indexOf('2. B'), greaterThanOrEqualTo(0));
      expect(out.indexOf('1. A'), lessThan(out.indexOf('2. B')));
    });

    test('appends age when present, omits the suffix when not', () {
      final out = WebSearchService.formatForLlm(
        'q',
        const [
          BraveSearchResult(
            title: 'A',
            url: 'https://a',
            description: 'd',
            age: '3 days ago',
          ),
          BraveSearchResult(
              title: 'B', url: 'https://b', description: 'd'),
        ],
      );
      expect(out, contains('https://a  (age: 3 days ago)'));
      // No bare `(age: )` for entry B.
      expect(out, isNot(contains('https://b  (age:')));
    });

    test('empty result list emits a clear "0 results" envelope', () {
      final out = WebSearchService.formatForLlm('vague query', const []);
      // Important: model needs an explicit "0 results" cue so it
      // doesn't think the previous turn was a parse failure and try
      // again with the same query.
      expect(out, contains('(0 results'));
      expect(out, contains('query: "vague query"'));
    });

    test('respects the budget by trimming the tail with a footer', () {
      // 30 dummy results with long descriptions → far exceeds the
      // default 4 KB budget.  Force a tiny budget here so we don't
      // depend on per-result sizing for the assertion.
      final results = List<BraveSearchResult>.generate(
        20,
        (i) => BraveSearchResult(
          title: 'Result $i',
          url: 'https://example.com/$i',
          description: 'desc $i — ${'x' * 50}',
        ),
      );
      final out = WebSearchService.formatForLlm(
        'overflow',
        results,
        budgetChars: 400,
      );
      // We must see SOME entries, but NOT all 20.
      expect(out, contains('1. Result 0'));
      expect(out.contains('20. Result 19'), isFalse);
      // The omission footer is the model's only signal that more
      // results exist — assert it's emitted.
      expect(out, contains('omitted to fit context budget'));
    });

    test('escapes `"` inside the query line', () {
      // The query line uses double quotes as delimiters; an unescaped
      // quote inside would make the line visually ambiguous.
      final out = WebSearchService.formatForLlm(
        'how to "quote" in bash',
        const [
          BraveSearchResult(
              title: 't', url: 'https://x', description: 'd'),
        ],
      );
      expect(out, contains(r'query: "how to \"quote\" in bash"'));
    });
  });

  group('WebSearchService.formatErrorForLlm', () {
    test('every error kind produces an envelope with recovery hint', () {
      for (final kind in WebSearchErrorKind.values) {
        final e = WebSearchException(kind, 'fixture message');
        final out = WebSearchService.formatErrorForLlm('q', e);
        expect(out, contains('[Web search failed]'),
            reason: 'kind=${kind.name} missing envelope header');
        expect(out, contains('reason: ${kind.name}'),
            reason: 'kind=${kind.name} missing reason line');
        expect(out, contains('fixture message'),
            reason: 'kind=${kind.name} missing upstream message');
        // The recovery hint is what stops the model from blindly
        // retrying the same query in a loop — every kind must ship
        // one even if it's just "proceed without".
        final recoveryStart = out.indexOf('\n\n');
        expect(recoveryStart, greaterThan(0),
            reason: 'kind=${kind.name} missing recovery block');
        expect(out.substring(recoveryStart).trim(), isNotEmpty,
            reason: 'kind=${kind.name} empty recovery body');
      }
    });

    test('missingKey error explicitly tells model not to retry', () {
      // Permanent-failure kinds need the strongest "do not retry"
      // language — otherwise GPT-class models often retry the marker
      // expecting a transient failure.
      final out = WebSearchService.formatErrorForLlm(
        'q',
        const WebSearchException(
            WebSearchErrorKind.missingKey, 'no key'),
      );
      expect(out.toLowerCase(), contains('do not retry'));
    });

    test('rateLimit error suggests waiting, not "do not retry"', () {
      // Transient failure — retrying after cooldown IS the right path.
      final out = WebSearchService.formatErrorForLlm(
        'q',
        const WebSearchException(
            WebSearchErrorKind.rateLimit, '429'),
      );
      expect(out.toLowerCase(), isNot(contains('do not retry')));
    });
  });
}
