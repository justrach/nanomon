# Third-party notices

nanomon's own source code is licensed under the MIT License in
[`LICENSE`](LICENSE). The material below keeps its own copyright and license.

## nanoui

nanomon is built on [nanoui](https://github.com/justrach/nanoui), Copyright (c)
2026 Rach Pradhan, under the MIT License. nanoui carries its own notices for
mygo (MIT) and GPUI (Apache 2.0) in its
[`THIRD_PARTY_NOTICES.md`](https://github.com/justrach/nanoui/blob/main/THIRD_PARTY_NOTICES.md).

## CodeGraff and Harness (external license)

nanomon uses these from [CodeGraff](https://github.com/justrach/codegraff) and
[Harness](https://github.com/justrach/harness):

- **The Codegraff Dark and Light palettes** (`src/theme.zig`), after
  [Harness](https://github.com/justrach/harness).
- **graff in the bubble**: nanomon runs the `graff` you have installed as its
  own program (`graff -p --no-local-tools`). It does not bundle or modify
  graff.

These parts are derived from CodeGraff and come under the license CodeGraff
ships with: CodeGraff's **modified GNU AGPLv3**, Copyright (C) 2026 Rach
Pradhan and Yu Xi Lim. That license, not MIT, stays their license. It is kept
here as the original, verbatim, in
[`third_party/licenses/CodeGraff-LICENSE.txt`](third_party/licenses/CodeGraff-LICENSE.txt)
(from CodeGraff
[`389b261`](https://github.com/justrach/codegraff/blob/389b26182fef0b8070d9a976505286d693876b6c/LICENSE)).
Harness is distributed under the same modified AGPLv3 terms.

The graff features work only with graff, which you install separately under
that license. Without graff installed, the bubble says graff isn't installed; the rest of nanomon works as usual.

nanomon's MIT license covers nanomon's own code. It does not extend to CodeGraff,
Harness or graff.
