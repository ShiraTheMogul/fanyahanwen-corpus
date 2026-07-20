# Atlas source structure

`content/atlas/entries/` contains human-edited polity records and articles.
`content/atlas/periods/` contains typed period and subperiod records.
`content/atlas/periodisation.json` controls public macro-region navigation.
Generated catalogues belong under `storage/corpus_search/atlas/`.

## Connecting one polity across several periods

Continuity is explicit. The compiler does not assume that two same-name states
are the same historical entity merely because their names match.

One polity page may claim several periods and corpus folders:

```json
{
  "id": "example-polity",
  "kind": "polity",
  "name": {
    "display": "Example polity",
    "hanzi": "例國",
    "alt": ["舊名"]
  },
  "corpus": {
    "root": "中國漢文",
    "polity": "例國",
    "polities": ["例國", "舊名"],
    "paths": [
      "中國漢文/clean/甲時代/例國",
      "中國漢文/clean/乙時代/舊名"
    ]
  },
  "atlas": {
    "period_ids": ["甲時代", "乙時代"]
  }
}
```

`corpus.polities` is optional. Use it only when the same historical entity is
represented by different polity values in different corpus periods.

For unrelated states sharing a name, keep separate entry records with separate
IDs, period IDs, and paths. For example, a Spring-and-Autumn `宋` should not be
merged with the Song dynasty merely because both are written `宋`.
