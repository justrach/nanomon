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

CodeGraff is Copyright (C) 2026 Rach Pradhan and Yu Xi Lim and is distributed
under its **modified GNU AGPLv3** terms, which are not MIT. The complete notice
is the CodeGraff
[`LICENSE`](https://github.com/justrach/codegraff/blob/389b26182fef0b8070d9a976505286d693876b6c/LICENSE)
(as of `389b261`). Harness is distributed under the same modified AGPLv3
terms; see its [`LICENSE`](https://github.com/justrach/harness/blob/b0c28b072ce35f5ce8c9a1249435ff404b6ffc97/LICENSE) (as of `b0c28b0`).
Your use of graff itself is governed by CodeGraff's license, not by nanomon's.
The MIT license on nanomon does not extend to CodeGraff or Harness.
