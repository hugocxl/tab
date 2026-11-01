# Third-party notices

## T3 Code

The Agent Tab integration uses T3 Code's provider adapters, protocol fixtures,
model manifest and chat components as implementation references, with selected
behaviors, model presets, interface patterns and test scenarios adapted to native
Swift. The native conversation terminal-output renderer adapts the SGR palettes,
contrast rules and bounded cursor-window behavior in `packages/shared/src/terminalOutput.ts`.

The underlying third-party code remains under its original copyright and license.
Legacy persisted citation, clipboard and embedded-app metadata identifiers remain
readable where required.

Source: https://github.com/pingdotgg/t3code
Reference revisions: `6fc9144a60c4a5f45089316ddd5f7371bafd3bf2` (initial integration)
and `e5909e53c32a9d5b51caf6352d1f17fd73e86db7` (conversation components and file icons).

MIT License

Copyright (c) 2026 T3 Tools Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Lucide conversation icons

Conversation control SVGs are from Lucide 0.564.0, matching the T3 Code reference lockfile.
Source: https://github.com/lucide-icons/lucide/tree/0.564.0/icons
The SVG stroke color is set to black for AppKit template tinting; paths are unchanged. Wrap and play strokes use T3's computed 1.75px CSS override.

ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2026 as part of Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors 2026.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

The MIT License (MIT) (for portions derived from Feather)

Copyright (c) 2013-2026 Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Pierre file icons and T3 file icon overrides

The conversation file-icon catalog uses SVG artwork and filename/extension rules
from `@pierre/trees` 1.0.0-beta.6, with T3 Code's overrides from revision
`e5909e53c32a9d5b51caf6352d1f17fd73e86db7`. Sprite symbols are expanded into
standalone SVGs and CSS theme colors are resolved into light/dark variants.
The resolver is adapted to Swift; no JavaScript package is used at runtime.

Pierre source: https://github.com/pierrecomputer/pierre
Apache 2.0 license and upstream notices are included in
`Sources/TabApp/Resources/Icons/PIERRE-LICENSE.txt` and `PIERRE-NOTICE.txt`.
T3 additions are covered by its MIT license above; its Lucide-derived icons
are also covered by the Lucide notices above.
