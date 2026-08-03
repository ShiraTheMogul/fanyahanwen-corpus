# Biographical and ancestral painting inscription overlay

Built 2026-08-03 for the Fanya Hanwen Corpus.

## Contents

- `11` promoted corpus works with validated JSON sidecars.
- `11` review packages containing useful draft transcriptions or institutional evidence but not yet safe for the clean tree.
- A register covering all 46 supplied sources.

## Geographic filing rule

Japanese works use `period / historical province or domain / work`. The geographic layer is not optional when it can be identified. It is based first on the object or text's production, dedication, institutional, or transmission context; the subject's biography is only a fallback. This prevents, for example, a portrait preserved and inscribed in 三河国 from being filed automatically under 尾張国 merely because it depicts Oda Nobunaga.

The recent flattened Mori path is **not** treated as precedent. Mori material tied to Aki is to be placed under `安芸国`.

## Text policy

- Published or institutional transcriptions are checked against the image.
- `〓` means a graph is genuinely unresolved or lost. It is not a request to guess.
- Japanese prose, kana glosses, and kanbun reading marks are not silently flattened into Literary Chinese. Mixed works stay in the register until the Hanwen unit can be delimited.
- Titles describe the inscribed text, not merely the museum object's English filename.
- Work/document IDs are explicitly `null`; the repository metadata-ID reconciler assigns distinct IDs automatically before manifest generation.

## Applying

Copy the contents of `corpus/` over the repository's `corpus/` directory, review the queued items, then run the normal manifest rebuild and its validation suite. No Rails routes are changed.

## GitHub draft status

The branch contains the reviewable text and metadata layer. The binary source images are listed in `asset_manifest.tsv` and are present in the full overlay archive delivered with this work, but were not transferred through the GitHub connector. The draft pull request is therefore intentionally **not merge-ready** until those exact assets are copied into their recorded paths and the normal metadata-ID/manifest validation is run.
