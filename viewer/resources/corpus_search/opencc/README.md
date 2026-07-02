# OpenCC character dictionaries used by corpus search

These files are vendored from the official BYVoid/OpenCC repository and are
used only for the **Broad script equivalents** search level.

Included dictionaries:

- `STCharacters.txt` — simplified to traditional character mappings
- `TSCharacters.txt` — traditional to simplified character mappings
- `JPShinjitaiCharacters.txt` — Japanese shinjitai to traditional character mappings

The corpus search treats these character correspondences as inspectable,
bidirectional search edges. It does not run phrase conversion and never rewrites
stored corpus text.

Source: https://github.com/BYVoid/OpenCC
Retrieved: 2026-07-02
License: Apache-2.0; see `LICENSE`.
