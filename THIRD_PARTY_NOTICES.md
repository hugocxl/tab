# Third-party notices

Tab includes the following third-party software and artwork. Each remains under
its original copyright and license.

## Ghostty

The terminal engine is libghostty-vt, built from Ghostty and statically linked
into `tabd`.

Source: https://github.com/ghostty-org/ghostty

MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

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

## T3 Code

Agent Tabs bundle artwork and rules adapted from T3 Code:

- Git host icons (`agent-host-*.svg`), with their view boxes, paths and gradients
  preserved.
- The file-icon overrides in `agent-file-icons.json` (see Pierre below).
- The terminal-output rendering of tool results: SGR contrast correction and the
  64-line live window with a bounded scrollback tail.

Source: https://github.com/pingdotgg/t3code
Reference revision: `e5909e53c32a9d5b51caf6352d1f17fd73e86db7`

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

## Pierre file icons

The file-icon catalog uses SVG artwork and filename/extension rules from
`@pierre/trees` 1.0.0-beta.6, with sprite symbols expanded into standalone SVGs
and theme colors resolved into light and dark variants. The resolver is written
in Swift; no JavaScript runs.

Source: https://github.com/pierrecomputer/pierre
The Apache 2.0 license and upstream notices are bundled as
`Sources/TabApp/Resources/Icons/PIERRE-LICENSE.txt` and `PIERRE-NOTICE.txt`.

## herdr

Agent detection manifests and region extraction are adapted from herdr.

Source: https://github.com/herdrdev/herdr
The Apache 2.0 license and attribution are bundled as
`Sources/TabServer/Resources/Detection/LICENSE-herdr` and `THIRD_PARTY.md`.

## serve-sim

Device panes call Xcode's simulator frameworks the way serve-sim does. Tab
follows its notes on the Indigo HID hardware button codes and targets. No
serve-sim code is included.

Source: https://github.com/EvanBacon/serve-sim (Apache 2.0)

## Android Emulator control protocol

Device panes talk to Android emulators over the emulator's gRPC control
protocol from the Android Open Source Project, implemented in Swift. No AOSP
code is included.

Source: https://android.googlesource.com/platform/external/qemu (Apache 2.0)
