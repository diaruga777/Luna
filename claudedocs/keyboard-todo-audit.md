# Clack PDF → Luna Keyboard

Source: **Clack todo list.pdf**, supplied 30 September 2026. This records every
line of the two-page list, including its examples and memory observations.

## Page 1

| PDF item | Outcome |
| --- | --- |
| Apply autocomplete on Send | Keyboard Return/Send applies the current eligible correction before inserting the return. Covered by a regression test. An external app's Send button has no supported pre-send callback for a keyboard extension; that part remains an iOS limitation. |
| Reduce memory (20 MB baseline, 24 MB without subviews) | Prediction engine is created on demand and discarded on release; key drawing remains one view, suggestion buttons are reused and cleared, redundant trait rebuilds are skipped, search responses and caches are bounded. Historical Clack numbers are not comparable to this simulator build; physical-device memory measurement remains unverified. |
| Custom emoji and ASCII mappings | Existing catalog editor retained; custom mappings take priority and can now be explicitly marked cosmetic. |
| Camera roll autocomplete | Photos picker imports a chosen image into a keyword shortcut. Matching keywords suggest that photo; copying remains limited to 8 MB. This does not automatically classify an entire photo library. |
| Swipe typing | Existing local decoder retained and tested; also taught in Keyboard Quest. |
| Hold top row for numbers | Existing number alternatives retained; tutorial teaches Q → 1, tests verify the mapping. |
| VoiceOver and styled ASCII | Keys speak plain letters and named controls, with style hints. Styled suggestions speak plain text; emoji and built-in ASCII suggestions use catalog names. Host apps control how inserted Unicode is spoken afterward. |
| Tutorial that demonstrates gestures | Show Me animates a pointer and executes keyboard actions on a disposable editor. Reduced Motion hides pointer movement. |
| 8-bit knight and dragon walkthrough | Four-lesson Keyboard Quest in the containing app, with pixel sprites, completion feedback and replay. |
| “dragonloser” deletion example | First quest lesson removes “loser” with reversible backspace dragging. |
| Delete missing glyph-store files | Shortcut menus identify missing media and offer replacement; explicit cleanup removes missing shortcuts and their keywords. |
| Compare Apple emoji suggestions | Checked Apple's documentation: predictive emoji are selected by tapping. Luna retains explicit selection rather than automatic emoji replacement. |
| Share shortcuts with other users | Versioned .lunakeyboard JSON files include keywords, flags and up to 8 MB of media. Import previews content and creates fresh identifiers and owned files. |
| Save GIPHY/Qwant metadata and deduplicate | Explicit search results cached for 24 hours, at most 20 queries, 24 unique HTTPS results per query. No media-byte cache. |
| Different iPad key set | iPad letter layout adds Tab, punctuation, right Shift, Return and Hide Keyboard. |
| iPad downward flick | Flick down inserts the displayed first alternative; top row maps to numbers. |
| Missing media after transfer / premium | Missing files are suppressed from typing suggestions and can be replaced without losing keywords. Sharing embeds bytes. Luna Keyboard has no legacy Clack premium purchase state to migrate. |
| Explicit cosmetic flag | Persisted flag; cosmetic shortcuts are suggested but never auto-applied. |
| Lookup content without autocomplete | Persisted lookup-only option hides a shortcut from typing suggestions while keeping it in Saved search. |
| Other themes | System, Moonlight, Ocean and High Contrast in Preferences. |

## Page 2

| PDF item | Outcome |
| --- | --- |
| Firefox URL bar / Mail typing | URL/email fields disable automatic correction, smart punctuation and automatic capitalization. Context changes invalidate pending correction state. Real Firefox/Mail extension behavior remains a device check. |
| Cannot type original after backspacing (“Hi em”) | Backspace rejects the current correction; entering a separator does not immediately reapply it. |
| Autocomplete broken | Added deterministic tests for lexicon corrections, rejection, timing, Return, quotes, punctuation and field restrictions. Existing adjacent-key ranking remains. |
| Preserve punctuation after correction undo | Undo restores the original spelling while retaining punctuation. The autocomplete follow-up now retains separator spaces too; see [keyboard-autocomplete-audit.md](keyboard-autocomplete-audit.md). |
| Ellipsis without a space treated as word | Tokenizer excludes punctuation and closing quotes; only interior apostrophes belong to words. |
| Lowercase sentence word when inserting before it | Bounded session history tracks words Luna automatically capitalized. Inserting a word and space before one lowercases its first letter. Existing pasted or manually capitalized text is not inferred from case alone. |
| Memory findings Google Doc | Linked document could not be retrieved. No claims are made about its unobserved contents. Current architecture and limits are recorded above. |
| “Board without adding subviews: 12.3” | Historical observation retained as context; current keyboard is drawn in one view and bounded-view regression coverage remains. No new device memory number is asserted. |
| UITextChecker preceding context | Existing preceding 256-character context and UTF-16 word range retained and tested. |
| Drag forwards to unselect should vibrate | Restoring characters during a deletion drag uses the same preference-controlled haptic as removing them. |
| Typing a letter kills backspace timer | Every non-delete key cancels repeat deletion immediately; touch reset also invalidates timers. |
| Inverse keypress volume | Replaced hard-coded AudioServices sound ID with UIInputViewAudioFeedback and UIDevice.playInputClick, which respect system keyboard click settings. Physical loudness is not measurable in the simulator. |
| Empty backspace vibrations | Empty delete and unchanged drag distance produce no deletion haptic. |
| Timed automatic correction / reverse loading bar | Eligible automatic corrections expire after two seconds; a shrinking strip shows the remaining interval. Manual suggestion selection remains available. |
| Repeated quote characters | Contextual opening/closing quotes, a preference to disable them, and a repeated-quote regression test. |
| Space then ? removes space without reverting correction | Closing punctuation removes one preceding separator and preserves the applied correction. |
| Wait before backspace to delete rather than undo | Automatic correction undo lasts one second. Later backspace deletes normally. |
| “Allow Paste from Other Apps” setting | Added Apple's UIPasteControl to Try It Out. Paste permission is controlled by iOS; no unsupported Info.plist key was added. |

## Verification and limits

- `LunaKeyboard` app, extension and hosted tests built with Xcode 26.2 / iOS 26.2.
- Final test count and result are in `keyboard.md`.
- Tests use temporary stores, including archive imports, repair/cleanup, lookup flags,
  cache bounds, correction behavior, iPad layout and all four tutorial demonstrations.
- The containing app home screen was visually checked. The Mac was locked during
  interactive simulator inspection, so gesture, Photos-picker and VoiceOver device
  checks remain unverified. No WebDriverAgent was installed or used on an iPhone.
- This work does not claim to intercept another app's Send button, reconstruct
  files missing from all backups, or restore purchases from the old Clack product.

## Platform references

- [Custom keyboard text interactions](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- [System input clicks](https://developer.apple.com/documentation/uikit/uidevice/playinputclick())
- [UIPasteControl](https://developer.apple.com/documentation/uikit/uipastecontrol)
- [Apple predictive emoji](https://support.apple.com/en-au/102507)
