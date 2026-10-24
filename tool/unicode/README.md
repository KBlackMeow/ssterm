# Terminal character widths

`16.0.0/` contains unmodified Unicode Character Database inputs:

- https://www.unicode.org/Public/16.0.0/ucd/EastAsianWidth.txt
- https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt

These files retain their Unicode copyright and license notices. They are pinned
locally so regeneration and tests are deterministic and work offline.

The modern profile assigns two cells to East_Asian_Width W/F or
Emoji_Presentation characters, after the terminal's combining/control rules.
Emoji, Extended_Pictographic, and Emoji_Presentation are different properties:
being eligible for emoji presentation does not make a bare text symbol wide.
VS16/VS15 presentation handling and the configurable ambiguous-width policy
remain separate from default scalar widths. The historical legacy profile
retains its existing Unicode 11 data.

After changing the pinned Unicode version or input files, update provenance and
regenerate both language tables from the repository root:

```sh
dart tool/generate_unicode_width_data.dart
dart tool/generate_terminal_width_table.dart
sh tool/test_rust_terminal_core.sh
```

Both generators support `--check`. The Unicode conformance test checks every
emoji's default presentation and every nonzero scalar width against the input
files; the native parity test checks every scalar under both width profiles and
ambiguous-width settings. Strix's six-cell sweep has a redraw regression for
both parsers so width changes cannot silently turn an updating row into a flood.
