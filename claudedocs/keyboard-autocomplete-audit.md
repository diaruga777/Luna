# Autocomplete improvements

Source: **Clack autocomplete improvements.pdf**, supplied 30 September 2026.
All twelve items and the additional dashes-mode request are covered below.

| Request | Implementation |
| --- | --- |
| Feed selected suggestions back to Apple | Explicitly choosing a word saves it in Luna’s dictionary for the suggestion’s language and calls `UITextChecker.learnWord`. Choosing the literal typed-word suggestion can teach a new spelling. Automatic corrections, calculator results, styles, links and media are not learned. Apple exposes spell-check dictionary learning; no predictive-model training or ranking-feedback API is used. |
| Prioritize adjacent-key typos | Existing QWERTY geometry and weighted edit distance retained: adjacent substitutions cost 0.45, distant substitutions cost 1; checker order breaks ties. Existing ranking and swipe tests remain in the suite. |
| Backspace preserves the following nonletter | Undo replaces only the corrected word and retains its complete suffix, including a lone space. This supersedes the earlier todo’s space-removal behavior. |
| Permit punctuation followed by spaces before undo | Tracks up to 16 trailing nonletters, including repeated punctuation, quotes and spaces. The existing one-second undo window remains. A new word, cursor/context change, or expiry invalidates undo. Double-space period updates the tracked suffix. |
| Do not correct `babyyyyyy` | Four consecutive copies of a letter, ignoring case, suppress automatic spelling/lexicon replacement. |
| Long-press suggestion to remove personal word | Personal suggestions have a context menu with “Remove from Personal Dictionary” and an equivalent VoiceOver action. Removal updates the appropriate Luna language dictionary and calls `UITextChecker.unlearnWord`. Apple’s learned-word dictionary is global across languages; Luna’s entries remain language-specific. |
| Paste suggestion when empty | A system `UIPasteControl` occupies the suggestion strip when both cursor contexts are empty, Full Access is available, and clipboard metadata indicates text. Content is loaded only after the user invokes Paste. Late loads are discarded after edits or disappearance; text is limited to 1 MB. |
| Never correct ordinals such as `1st` / `21st` | The tokenizer keeps digits with adjoining letters; tokens containing digits bypass automatic correction rather than treating `st` as a separate word. |
| Applied text styles should disappear from suggestions | Markdown transformations have their own suggestion kind. No-op quote wrappers are suppressed, and the resulting styled text no longer offers the applied transformation. |
| Do not capitalize after `e.g.` | Sentence detection recognizes `e.g.`, `i.e.`, `etc.`, `Mr.`, `Mrs.`, `Ms.`, `Dr.`, `Prof.` and `vs.` as abbreviations. Newlines and normal sentence endings still capitalize. The extension also correctly respects the host’s explicit `.none` capitalization trait. |
| SpongeBob never has three identical cases consecutively | SpongeBob is available under **Aa → Styles**. Random casing consults the two preceding cased letters, including across keystrokes and word boundaries. Unicode case expansions are checked per output letter. Swipe alternatives replace the actual inserted casing rather than regenerating a random replacement token. |
| Calculator autocomplete | Manual `= result` suggestions support decimal arithmetic, parentheses, unary signs, multiplication/division and postfix percentages. A bounded arithmetic parser rejects malformed input, division by zero, nonfinite results and identifier/URL suffixes. Selecting the result preserves the space before the expression. Results never apply on Space or Return. |
| Dashes mode | On **123**, hold **-** and slide to **Dashes**. The board returns to letters and the spacebar displays/inserts a literal **-**, including when a text style is selected. Double-space period is bypassed. Hold **-** again and choose **Spaces** to exit. VoiceOver exposes a toggle on the dash and space keys. Holding the wide key still supports cursor movement. The mode lasts for the current keyboard instance. |

## Verification

The `LunaKeyboard` scheme builds the containing app and extension and runs the
**53 hosted tests, 0 failures**, on iPhone 17 Pro / iOS 26.2 with Xcode 26.2
and normal simulator signing.
Tests cover dictionary selection/removal, paste eligibility and delayed delivery,
calculator parsing and application, ordinal/repeat guards, abbreviation casing,
style suggestions, correction suffixes, dash-mode entry/exit, SpongeBob chunks,
Unicode expansions and swipe replacements. They use disposable stores.

The tryout screen was launched and captured. The Mac was locked during inspection:
Blitz and XcodeBuildMCP returned an empty accessibility hierarchy, so physical
long-press/slide gestures and the system paste permission flow remain unverified.
No WebDriverAgent was installed or used on an iPhone.

## Apple API references

- [UITextChecker.learnWord](https://developer.apple.com/documentation/uikit/uitextchecker/learnword(_:)) adds a word to the spell-check dictionary, globally across languages.
- [UITextChecker.unlearnWord](https://developer.apple.com/documentation/uikit/uitextchecker/unlearnword(_:)) removes a learned word.
