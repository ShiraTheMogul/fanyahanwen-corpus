# Validation record

Validation date: 2026-07-17 UTC

## Inputs checked

```text
viewer(8).zip
SHA-256 d635f3d327faf6dd51210f908fb891e4f4d9f7c255d8f24f6969d47f668c3a99

商殷朝.zip
SHA-256 72410db4d393a9cc6e2ed980f1c2aa5c9a1e8e535e8700f27f81c934478e3d55
```

The patch was built against the exact latest viewer archive above. All patch paths were new; no existing script, configuration file, test, or route file was overwritten.

## Automated tests

```text
3 runs
44 assertions
0 failures
0 errors
```

## Full dry run against the uploaded 商殷朝 archive

```text
metadata files read                 24,660
physical oracle-bone objects        13,906
bronze objects                       2,633
object/collection metadata outputs  16,541
corpus/support files planned        29,658
work-ID alias rows                  24,655
unparsed rows                            0
warnings                                 0
elapsed                              37.2 seconds
```

The 29,658 planned files account for every non-`metadata.json` file in the supplied archive:

```text
unaccounted source files  0
missing source references 0
duplicate source moves    0
duplicate target moves    0
duplicate metadata paths  0
duplicate work IDs        0
duplicate document IDs    0
```

## Full apply test on a disposable copy

The reviewed plan was applied to a copy of the uploaded archive.

```text
files moved                  29,658
metadata sidecars written    16,541
metadata/document path errors     0
old 甲骨 root removed             yes
old 金文 root removed             yes
old 花園庄（洹北） root removed   yes
new top-level polity folders      商, 周方, 子方, 土方
```

The test also deliberately resumed an interrupted apply. Already moved files were accepted only when their SHA-256 hashes matched the reviewed plan.

## Deferred by design

```text
image acquisition and rights review
viewer controls for switching transcription/image layers
scholarly population of concordance and per-object override CSVs
Rails route changes (none were made)
```
