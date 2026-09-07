# Third-party notices

Luna ships no third-party source in these files. The notices below cover
routines and designs ported into Luna's own code.

## swift-markdown-engine

<https://github.com/nodes-app/swift-markdown-engine>

Copyright 2026 Luca Chen. Licensed under the Apache License, Version 2.0.
You may obtain a copy of the License at
<http://www.apache.org/licenses/LICENSE-2.0>.

Luna Writer's live-Markdown editor ports two routines and one design from
this AppKit package. The package itself is not vendored or linked.

- `LunaLibraries/Sources/LunaWriterEditor/Text/LayoutAttributeStyler.swift`
  — the hidden-marker recipe: a near-zero point size plus a per-character
  negative kern that cancels the run's own width
  (`MarkdownStyler.hiddenRunKern`).
- `LunaLibraries/Sources/LunaWriterEditor/Rendering/WriterTextLayoutFragment.swift`
  — the decoration set an `NSTextLayoutFragment` subclass paints over
  collapsed markers: a bullet, a checkbox, one bar per blockquote level and
  a rule for a thematic break (`MarkdownTextLayoutFragment`).
