# Automatic corpus metadata-ID repair

`bin/rails corpus_search:rebuild_manifest` now repairs metadata IDs before it reads the corpus.

The repair pass treats IDs as machine keys:

- every work, document, and edition receives a positive JSON integer;
- IDs are unique within their kind;
- missing IDs receive new numbers;
- duplicate claims are resolved deterministically;
- searchable TXT files omitted from metadata receive document records;
- text directories with no metadata ancestor receive a minimal `metadata.json`;
- the current registry is rebuilt at `<corpus root>/.metadata_id_registry.csv`.

## Duplicate rule

For two current entities claiming the same number:

1. the entity explicitly associated with that number in the registry keeps it;
2. otherwise the lexically first identity keeps it;
3. every other claimant receives the next unused number above the recorded maximum.

A collision therefore does not stop a manifest rebuild.

## Safety boundary

The repair only stops when it cannot determine the corpus contents reliably, for example because a directory is unreadable. Existing metadata and registry files are backed up beneath:

```text
tmp/corpus_metadata_ids/backups/
```

Each run also writes a CSV change report and a JSON summary beneath `tmp/corpus_metadata_ids/`.

## Commands

The usual manifest command performs the repair automatically:

```bash
bin/rails corpus_search:rebuild_manifest
```

The same pass can be run by itself:

```bash
bin/rails corpus_metadata_ids:repair
```

On the first run, the task can seed the canonical registry from the newest older registry under `tmp/corpus_metadata_json/**/metadata_id_registry.csv`. An explicit seed can be supplied with:

```bash
CORPUS_METADATA_ID_SEED_REGISTRY=/path/to/metadata_id_registry.csv \
  bin/rails corpus_metadata_ids:repair
```
