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

Tab includes rules and rendering adapted from T3 Code:

- The file-name override rules used by the file-icon resolver.
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

## Tab Icons

Tab Icons is Tab's own icon set, adapted and extended from two foundations:

- `@pierre/icons` 0.9.0, under Apache 2.0:
  https://github.com/pierrecomputer/icons
- Pierre's file icon library, `pierrecomputer/vscode-icons`, under MIT:
  https://github.com/pierrecomputer/vscode-icons

Both license texts are bundled in `Sources/TabApp/Resources/TabIcons/LICENSE`.

The set's brand marks (agent providers, Git hosts, runtimes, languages and
tools) are simplified adaptations of the brands' own marks, taken from:

- Simple Icons 16.37.0 (CC0 1.0): https://github.com/simple-icons/simple-icons.
  Brand marks remain the trademarks of their owners; see its DISCLAIMER.
- LobeHub Icons 1.102.0, `@lobehub/icons-static-svg`, under MIT:
  https://github.com/lobehub/lobe-icons
- Devicon 2.18.0, under MIT: https://github.com/devicons/devicon

Their license texts are bundled in `Sources/TabApp/Resources/TabIcons/LICENSE`.

## herdr

Agent detection manifests and region extraction are adapted from herdr.

Source: https://github.com/herdrdev/herdr
The Apache 2.0 license and attribution are bundled as
`Sources/TabServer/Resources/Detection/LICENSE-herdr` and `THIRD_PARTY.md`.

## serve-sim

Simulator panes call Xcode's simulator frameworks the way serve-sim does. Tab
follows its notes on the Indigo HID hardware button codes and targets. No
serve-sim code is included.

Source: https://github.com/EvanBacon/serve-sim (Apache 2.0)

## Android Emulator control protocol

Simulator panes talk to Android emulators over the emulator's gRPC control
protocol from the Android Open Source Project, implemented in Swift. No AOSP
code is included.

Source: https://android.googlesource.com/platform/external/qemu (Apache 2.0)

## Cuelume

Tab's notification sounds are synthesized natively from the recipes of
cuelume's bubble family: their tones, pitch slides, noise pops, envelopes and
variation.

Source: https://github.com/danielwh2/cuelume

MIT License

Copyright (c) 2026 Daniel Belyi

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
