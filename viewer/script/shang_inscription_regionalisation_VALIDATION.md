# Validation record: corrected Shang regionalisation phase 1

Validation date: 2026-07-18 UTC

## Exact inputs

```text
viewer(9).zip
SHA-256 849a5877ceff27101e289b4a230fb2a6a9cc41dfb063294ba5de31d3b07233d8

商殷朝.zip
SHA-256 72410db4d393a9cc6e2ed980f1c2aa5c9a1e8e535e8700f27f81c934478e3d55
```

The correction was built cumulatively against the exact latest viewer archive above. It replaces the phase-one Shang script/configuration already present in that tree and adds the previously documented standalone test file.

No route file was changed.

## Corrected risks

The original dry run was structurally consistent but had two unsafe assumptions:

```text
new IDs were allocated above Shang-local maxima rather than corpus-wide maxima
HYZ 0.6 / 0.7 / 0.9 were collapsed into a fictional object called 花東0
```

The audit also identified three superseded source-collection work IDs (`50042`, `50043`, `50044`). The corrected plan preserves them as aliases of the new `甲骨文` collection rather than leaving stale registry rows.

## Automated fixture tests

```text
4 runs
31 assertions
0 failures
0 errors
0 skips
```

The tests exercise:

```text
global ID allocation above deliberately higher non-Shang IDs
H3：1573 / H3：1616 / H3：1630 separation
active work and document registry rewrites
translation-document registry rows
merged object and collection aliases
collision detection when an existing ID belongs outside 商殷朝
registry backup and atomic replacement
second-apply refusal
safe #Uxxxx decoding before hexadecimal identifier digits
```

## Full dry run against the uploaded Shang archive

A synthetic registry was generated from every existing Shang metadata record and given deliberately higher external ceilings:

```text
synthetic global work maximum      500,000
synthetic global document maximum  700,000
```

This registry is not presented as the user's authoritative registry. It was used to prove that allocation obeys arbitrary corpus-wide maxima rather than falling back to Shang-local values.

Dry-run result:

```text
metadata files read                  24,660
oracle transcription/translation docs 26,804
physical oracle-bone objects         13,908
bronze objects                        2,633
object/collection metadata outputs   16,543
corpus/support files planned          29,658
work-ID alias rows                    24,658
unparsed rows                              0
warnings                                   0
elapsed                                41.5 s
```

The two additional oracle objects compared with the original plan are the result of replacing one false `花東0` object with three actual excavation-number objects.

The three exceptional outputs were:

```text
H3：1573  work ID 500003
H3：1616  work ID 500004
H3：1630  work ID 500005
```

Their exact numeric IDs above are synthetic-test allocations only. The live run will allocate above the actual authoritative registry maximum.

Synthetic registry update:

```text
rows before                 51,897
rows after                  54,857
work maximum before/after   500,000 → 500,550
document maximum before/after 700,000 → 702,410
```

The increase is exactly:

```text
550 new physical/collection work IDs
2,410 previously unregistered translation document IDs
```

## Full apply on a disposable copy

The reviewed full plan was applied to a disposable extraction of the supplied archive.

```text
files moved                     29,658
metadata sidecars written       16,543
registry replacement digest matched reviewed file: yes
apply elapsed                    28.3 s
apply exit status                0
```

Post-apply audit:

```text
registry rows                     54,857
metadata files                    16,543
registered searchable/translation documents 29,645
metadata work registry errors          0
metadata document registry errors      0
missing moved document files           0
duplicate registry IDs                 0
duplicate registry identities          0
old 甲骨 root remaining                 no
old 金文 root remaining                 no
old 花園庄（洹北） root remaining       no
```

The remaining thirteen planned moves are support/review files and therefore do not receive document IDs.

## Patch-file checksums

```text
script/shang_inscription_regionalisation.rb
c6c6b24860536c6e2d445a32160178a5222de65028166d006029a4f6dc37aa6f

config/corpus_metadata/shang_inscription_regionalisation.yml
8269a0a364b7fff1a2455a0c114359793469b88323bf38acb2e550fb44857b9a

config/corpus_metadata/shang_oracle_concordances.csv
d18ceed629f219ed0e8489c494dd3ff12f2b708e87788b30b20c7bf0bac0dd96

test/scripts/shang_inscription_regionalisation_test.rb
b5da7c956f7f8555911732da450869583f8b8cc93423dfb5378d73adc66d55a9
```

## Required live-run difference

The live dry run must use the exact `metadata_id_registry.csv` from the successfully applied JSON migration. The synthetic validation registry must never be copied into the project.

Because the script records and verifies the authoritative registry SHA-256, any registry change between planning and application forces a fresh plan.
