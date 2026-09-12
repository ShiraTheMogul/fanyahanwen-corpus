"""
Loader for the Fanyahanwen corpus tree.

Layout, as observed on disk:

    corpus/<國>漢文/clean/<macro_region>/<period>/<region…>/<work>/
        metadata.json
        <title>.txt              (one or more; juan are separate files)

`metadata.json` carries corpus_root, macro_region, period, polity, region,
title, authors and a `documents` list, and is the label source; the 54MB
`index_corpus.csv` is never touched. `body_start_line` in `documents[]` is
ignored, since in `clean/` the body starts at line 1 and the field disagrees.
Everything reads with `utf-8-sig`, so files with and without a BOM both work.

`group_key` exists so you can hold out an entire tradition: train on 中國漢文,
test on 日本漢文 / 朝鮮漢文 / 越南漢文. If it generalises across that split it is
measuring Literary Chinese; if it does not, it has learned to recognise Chinese
authorship. No aggregate accuracy number substitutes for that split.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Sequence


@dataclass
class Work:
    metadata_path: Path
    meta: Dict[str, object]
    text_paths: List[Path] = field(default_factory=list)

    @property
    def corpus_root(self) -> str:
        return str(self.meta.get("corpus_root", ""))

    @property
    def macro_region(self) -> str:
        return str(self.meta.get("macro_region", ""))

    @property
    def period(self) -> str:
        return str(self.meta.get("period", ""))

    @property
    def polity(self) -> str:
        return str(self.meta.get("polity", ""))

    @property
    def title(self) -> str:
        return str(self.meta.get("title", self.metadata_path.parent.name))

    @property
    def work_id(self) -> str:
        return str(self.meta.get("work_id", self.metadata_path.parent.name))

    def read_text(self, *, joiner: str = "\n\n") -> str:
        parts = []
        for p in self.text_paths:
            try:
                parts.append(p.read_text(encoding="utf-8-sig"))
            except (OSError, UnicodeDecodeError):
                continue
        return joiner.join(parts)


def iter_works(root: str | Path, *, limit: Optional[int] = None) -> Iterator[Work]:
    """Walk a corpus subtree yielding one Work per metadata.json.

    Walking is lazy and per-directory. On the OneDrive-hosted copy a full
    recursive scan of `corpus/` is slow enough to look like a hang, so point this
    at a specific tradition or period rather than the corpus root when you are
    iterating.
    """
    root = Path(root)
    n = 0
    for meta_path in sorted(root.rglob("metadata.json")):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(meta, dict):
            continue

        folder = meta_path.parent
        texts: List[Path] = []
        docs = meta.get("documents")
        if isinstance(docs, list):
            for d in docs:
                if isinstance(d, dict) and d.get("file"):
                    cand = folder / str(d["file"])
                    if cand.exists():
                        texts.append(cand)
        if not texts:
            texts = sorted(folder.glob("*.txt"))
        if not texts:
            continue

        yield Work(metadata_path=meta_path, meta=meta, text_paths=texts)
        n += 1
        if limit is not None and n >= limit:
            return


def group_key(work: Work, level: str = "macro_region") -> str:
    """Key for held-out-group evaluation.

    level: 'corpus_root' | 'macro_region' | 'period' | 'polity' | 'work'
    """
    return {
        "corpus_root": work.corpus_root,
        "macro_region": work.macro_region,
        "period": work.period,
        "polity": work.polity,
        "work": work.work_id,
    }.get(level, work.macro_region)


@dataclass
class Sample:
    text: str
    label: int
    group: str
    source: str
    meta: Dict[str, object] = field(default_factory=dict)


def load_samples(
    positive_roots: Sequence[str | Path],
    negative_roots: Sequence[str | Path] = (),
    *,
    group_level: str = "macro_region",
    limit_per_root: Optional[int] = None,
    min_chars: int = 100,
) -> List[Sample]:
    """Build a labelled sample list.

    `positive_roots` are corpus subtrees whose works are Literary Chinese.
    `negative_roots` are directories of plain .txt files that are NOT — modern
    Mandarin prose, vernacular fiction, whatever you want the filter to reject.

    You have to supply the negatives. Every tradition in the Fanyahanwen tree is
    Literary Chinese, so the corpus on its own is a single-class dataset and a
    classifier trained on it would learn nothing except to say yes. `fit()` will
    refuse rather than produce a model that is right about everything by saying
    one word.
    """
    samples: List[Sample] = []

    for root in positive_roots:
        for w in iter_works(root, limit=limit_per_root):
            text = w.read_text()
            if len(text) < min_chars:
                continue
            samples.append(Sample(
                text=text, label=1, group=group_key(w, group_level),
                source=str(w.metadata_path.parent),
                meta={"title": w.title, "period": w.period,
                      "polity": w.polity, "corpus_root": w.corpus_root},
            ))

    for root in negative_roots:
        root = Path(root)
        paths = sorted(root.rglob("*.txt")) if root.is_dir() else [root]
        if limit_per_root is not None:
            paths = paths[:limit_per_root]
        for p in paths:
            try:
                text = p.read_text(encoding="utf-8-sig")
            except (OSError, UnicodeDecodeError):
                continue
            if len(text) < min_chars:
                continue
            samples.append(Sample(
                text=text, label=0, group=f"negative:{root.name}",
                source=str(p), meta={"title": p.stem},
            ))

    return samples


def summarise_samples(samples: Sequence[Sample]) -> Dict[str, object]:
    by_group: Dict[str, Dict[str, int]] = {}
    for s in samples:
        g = by_group.setdefault(s.group, {"positive": 0, "negative": 0, "chars": 0})
        g["positive" if s.label == 1 else "negative"] += 1
        g["chars"] += len(s.text)
    return {
        "total": len(samples),
        "positive": sum(1 for s in samples if s.label == 1),
        "negative": sum(1 for s in samples if s.label == 0),
        "groups": by_group,
    }
