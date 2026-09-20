# The chat hand-off

Apple Intelligence gets one silent attempt at a failed save and is never offered
as a button (`claudedocs/url-rescue.md`). What the USER can do about a failure is
this: tap ChatGPT or Claude on the card, answer the prompt Luna already wrote,
and bring the reply back as a Luna file (`claudedocs/luna-file.md`).

Luna never calls a model over the network and holds no API key. It opens the
provider's own app with the prompt in the URL, and the user is the one who
carries the answer back.

## The round trip

1. The card shows the hand-off row. The user taps a provider.
2. Luna builds `LLMHandoffPrompts.recovery(url:app:failure:)` — the page, one
   sentence naming what went wrong (`SaveFailureReason.rescueSentence`), the file
   shape to answer with, and the extension to name it.
3. It records the hand-off (`LLMHandoffStore`) and opens the provider's link
   (`LLMDeepLink`). The card flips to **waiting** and says which file extension
   to look for in the reply.
4. The model answers with one `luna-recovery` file. The user taps it, or shares
   it into Luna, or long-presses the code block and shares it as text.
5. `RecoveryFileApplier` applies it, the record is cleared, and the deck lands on
   the recovered save.

A record expires after 24 hours. A card cannot say "waiting" forever for a reply
the user abandoned.

## The links

| Provider | Opened first | Fallback |
| --- | --- | --- |
| ChatGPT | `chatgpt://new-chat?prompt=…` | `https://chatgpt.com/?q=…` |
| Claude (chat) | `https://claude.ai/new?q=…` | none — it is already the web |
| Claude (Code) | `https://claude.ai/code/new?q=…` | `claude://code/new?q=…` |

ChatGPT's own app is asked first because its web form opens Safari even when the
app is installed. Claude's is a universal link, which the app claims when it is
installed and the web serves when it is not.

Encoding keeps every delimiter as data: the allowed set is `urlQueryAllowed`
minus `& + = ? # /`, so a URL inside the prompt survives as a URL. A prompt whose
built link would pass `LLMDeepLink.maxURLCharacters` (8,000) yields **no link** —
a truncated prompt is a truncated instruction, and the prompt budget
(`LLMHandoffPrompts.maxCharacters`, 3,600) leaves the encoding room.

**Claude Code is a long press.** The Claude button carries a
`UIContextMenuInteraction` offering "Use Claude chat" / "Use Claude Code", and
the answer is remembered in `LLMProviderPreferences.claudeTarget` (App Group, so
the extensions build the same link the app does). Ordinary chat is the default:
Claude Code needs access not every user has.

## The row

`LLMHandoffRowView` (LunaDesignSystem) is the whole offer, and every surface
shows the same one: a caption, a glass button per provider, and a hint slot. The
provider marks are drawn in code (`LLMProviderGlyph`) as monochrome templates —
a hexagonal knot and an eight-armed burst — so they take the surrounding text's
colour, need no asset catalogue, and carry no trademarked artwork.

| Surface | Where |
| --- | --- |
| The failed save's card | `FailedSaveCardViewController`'s chin |
| The extension's failure card | `RescueFailureViewController`'s chin |
| The Downloader's no-media card | over the status bar, only for `.noMedia` |

## A save that worked, and is still wrong

A save can land `.ready` holding the wrong thing: the teaser behind a consent
wall, a different product, a preview clip. There is no failure to explain and no
card chin to put a row in, so the offer is a submenu on the card's LONG PRESS —
**Recover with AI**, one row per provider plus Claude Code — in every app
(`KindDeckProvider.deckMenu`). It is offered for a `.ready` save with an http(s)
page behind it; an imported `lunadoc://` document has no page to read again.

The prompt is the recovery prompt with a different sentence:
`SaveFailureReason.wrongContentSentence`, which names the ways a "successful"
capture is usually wrong for that kind rather than a failure that never
happened. `SaveFailureReason.attemptKind` answers the kind from the item's own
shape, so a platform item asks for media whatever its state.

`SaveRecoveryHandoff.begin` (`Luna/Saves/`) is the ONE place that records the
hand-off and opens the provider — the failed card's row, the Downloader's
no-media card and this menu all go through it. The menu then shows the waiting
line as a toast, once, because there is no chin to hold it; open the menu again
while the hand-off is live and its first row says so.

**The file replaces the content in place.** `RecoveryFileApplier` honours the
recorded hand-off first, in any state, so the reply lands on the row the user
asked about instead of reserving a second save. Each kind's handler makes that
true for what it already holds:

| Kind | What the handler does with what is there |
| --- | --- |
| article | Overwrites the content file and the row's columns. The old images are released through the `file_holders` edges; the new cover takes the row's artwork, which a first save's "only if absent" rule would have kept. |
| product | Updates the save's OWN tracker (`ProductTrackerIngestor.replaceOwnTracker`) — its sellers, their day-bucketed history, the `initialPrice` baseline and the alert threshold all stand, and it takes the new name, brand, identifiers, artwork and current price. The matcher deliberately excludes a save's own tracker, so without this branch the save would get a new tracker and lose its past. |
| media | Drops the library row and the already-downloaded marker (`MediaSavedContents.discard`) before the download hand-off, which otherwise answers "already downloaded" and keeps the wrong file. |

Each handler keys that on the row being `.ready` when it runs: a first save is
`.pending`, a rescue's is `.failed`, a plugin's is `.needsCaptcha`.

## Recording it

`LLMHandoffStore` (`llmHandoffs.json`, App Group) holds one record per hand-off
in flight: the id, what was asked for (a recovery for an item and a URL, or a
plugin request and the user's own words), the provider, the Claude target, and
when it started.

It is App Group backed because the two ends can be different processes: the
share extension's failure card can start a hand-off and the app applies the file
that comes back. Asking a second provider about the same page replaces the first
record rather than queueing behind it — the card shows one answer's worth of
waiting.

## When the extension cannot open a provider

An extension may only ASK its host to open a URL (`extensionContext.open`), and
the host may refuse. So the leg writes the record FIRST, then asks; when the
completion reports a refusal it opens the containing app at
`<scheme>://llm?item=<uuid>` instead. `KindWiring.openLLMHandoff` reads the same
record and opens the provider from the app, which is always allowed to. Either
way the record is already written, so nothing is lost if the second open fails
too — the card will offer the hand-off again.

## What is deliberately not here

- **No detection of whether the provider answered.** Luna cannot see the chat.
  The waiting state is a record with a clock on it, not a poll.
- **No API keys and no network call to any model.** The only model Luna calls is
  Apple's, on the device or through Private Cloud Compute.
- **Two providers.** `LLMProvider` is an enum; a third is a glyph, a URL shape
  and a strings line.

## Tests

`LunaTests/LLMDeepLinkTests.swift` — delimiter round-trips, the URL ceiling, the
Claude target switch, and which providers have a fallback.
`LunaTests/LLMHandoffStoreTests.swift` — lookup by item and by URL, replacement,
expiry, and two live stores over one file.
`LunaTests/FailedSaveTests.swift` — that a recorded hand-off puts the card in the
waiting state. `LunaTests/URLRescueTests.swift` — that a refused provider open
falls back to the containing app. `LunaTests/ArticleCardsChromeTests.swift` —
that a ready card's menu carries the submenu above Archive and a document's does
not. `LunaTests/RecoveryFileApplierTests.swift` — that the record wins over a
same-URL failed save and that a ready article is replaced in place.
`LunaTests/SaveContentReplacementTests.swift` — the tracker's history and the
media save's stale file.
