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

## @hugocxl/icons

Tab's icons come from @hugocxl/icons, the `Icons` library of the hugocxlStack
Swift package: https://github.com/hugocxl/stack. The set adapts `@pierre/icons`,
Pierre's file icons, Simple Icons, LobeHub Icons and Devicon; its `NOTICE` and
`THIRD_PARTY_LICENSES.md` ship inside the package's resource bundle.

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

## Geist (website)

The website uses Geist and Geist Mono through the @hugocxl design system, which
the site build copies from the `@hugocxl/design-system` npm package.

Source: https://github.com/vercel/geist-font

The fonts are distributed under the SIL Open Font License 1.1. The full
copyright and license text accompanies them in `system/fonts/Geist-LICENSE.txt`
in that package and on the published site.
