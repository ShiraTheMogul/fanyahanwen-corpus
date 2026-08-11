#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Normalize staged Wiktionary Chengyu evidence into inspectable lexical families.

This is intentionally a staging normalizer, not a database importer.

Input:
    <staging>/
      pages/*.csv
      definitions/*.csv
      pronunciations/*.csv
      relations/*.csv
      sections/*.csv
      templates/*.csv

Output (default <staging>/normalized/):
    families.csv
    forms.csv
    attestations.csv
    readings.csv
    senses.csv
    etymologies.csv
    provenances.csv
    form_relations.csv
    semantic_relations.csv
    diagnostics/*.csv
    manifest.json

Rules:
- Exact spelling equality is identity of the form, not a fuzzy merge.
- Only explicit *form* relationships merge forms into one family.
- Synonyms, short forms, initialisms and other semantic/derivational links never merge.
- Korean Hangul headwords are readings/input forms. They attach to explicit Hanja when supplied.
- Romanized zh-see POJ pages are readings of their Han target, not separate Chengyu forms.
- No simplified/traditional conversion, semantic similarity, story similarity, or edit distance
  is used to merge families.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Optional, Sequence, Set, Tuple

VERSION = "v2-wiktionary-chengyu-normalizer-2026-08-10"
SITES = ("enwiktionary", "zhwiktionary", "jawiktionary", "kowiktionary")
DEFINITION_LANGUAGE_BY_SITE = {
    "enwiktionary": "en",
    "zhwiktionary": "zh",
    "jawiktionary": "ja",
    "kowiktionary": "ko",
}

JOINABLE_DEFINITION_RELATIONS = {
    "alternative_form_of": "alternative_form",
    "uncommon_form_of": "uncommon_form",
    "misspelling_of": "misspelling",
    "misconstruction_of": "misconstruction",
}

READING_RELATION_SYSTEMS = {
    ("hanja_form_of", "ko"): ("hangul", "Hangul"),
    ("han_form_of", "vi"): ("vietnamese_orthography", "Vietnamese orthography"),
}

NONPLAYABLE_STATUSES = {"misspelling", "misconstruction"}

# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------

def split_multi(value: str) -> List[str]:
    return [part.strip() for part in (value or "").split(" || ") if part.strip()]


def bool_field(value: str) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes"}


def int_field(value: str) -> int:
    try:
        return int((value or "").strip())
    except (TypeError, ValueError):
        return 0


def read_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, fieldnames: Sequence[str], rows: Iterable[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: scalar(row.get(key, "")) for key in fieldnames})


def scalar(value: object) -> object:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (set, list, tuple)):
        return " || ".join(str(x) for x in value if str(x) != "")
    return value


def load_site_rows(staging: Path, group: str) -> Dict[str, List[Dict[str, str]]]:
    return {site: read_csv(staging / group / f"{site}.csv") for site in SITES}


# ---------------------------------------------------------------------------
# Unicode / form classification
# ---------------------------------------------------------------------------

def is_han_char(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3400 <= cp <= 0x4DBF
        or 0x4E00 <= cp <= 0x9FFF
        or 0xF900 <= cp <= 0xFAFF
        or 0x20000 <= cp <= 0x2A6DF
        or 0x2A700 <= cp <= 0x2B73F
        or 0x2B740 <= cp <= 0x2B81D
        or 0x2B820 <= cp <= 0x2CEAD
        or 0x2CEB0 <= cp <= 0x2EBE0
        or 0x2EBF0 <= cp <= 0x2EE5D
        or 0x30000 <= cp <= 0x3134A
        or 0x31350 <= cp <= 0x323AF
        or 0x323B0 <= cp <= 0x33479
        or 0x2F800 <= cp <= 0x2FA1F
    )


def has_han(text: str) -> bool:
    return any(is_han_char(ch) for ch in (text or ""))


def char_kind(ch: str) -> str:
    if is_han_char(ch):
        return "han"
    cp = ord(ch)
    if (
        0x3040 <= cp <= 0x309F
        or 0x30A0 <= cp <= 0x30FF
        or 0x31F0 <= cp <= 0x31FF
    ):
        return "kana"
    if (
        0xAC00 <= cp <= 0xD7AF
        or 0x1100 <= cp <= 0x11FF
        or 0x3130 <= cp <= 0x318F
    ):
        return "hangul"
    if ch in {"々", "〻", "〆", "〇"}:
        return "iteration"
    if "LATIN" in unicodedata.name(ch, ""):
        return "latin"
    if ch.isspace() or unicodedata.category(ch).startswith("P"):
        return "punctuation"
    return "other"


def classify_form(text: str) -> str:
    kinds = {char_kind(ch) for ch in text if not ch.isspace()}
    if not kinds:
        return "empty"
    if kinds <= {"han"}:
        return "han"
    if kinds <= {"han", "punctuation"} and "han" in kinds:
        return "han_with_punctuation"
    if kinds <= {"han", "iteration", "punctuation"} and "han" in kinds:
        return "han_with_iteration"
    if "han" in kinds and "kana" in kinds:
        return "han_kana_mixed"
    if "han" in kinds and "hangul" in kinds:
        return "han_hangul_mixed"
    if "han" in kinds:
        return "han_mixed"
    return "_".join(sorted(kinds))


def han_count(text: str) -> int:
    return sum(1 for ch in text if is_han_char(ch))


def contains_punctuation(text: str) -> bool:
    return any(char_kind(ch) == "punctuation" for ch in text if not ch.isspace())


def is_strict_han(text: str) -> bool:
    chars = [ch for ch in text if not ch.isspace()]
    return bool(chars) and all(is_han_char(ch) for ch in chars)


# ---------------------------------------------------------------------------
# Union-find
# ---------------------------------------------------------------------------

class UnionFind:
    def __init__(self) -> None:
        self.parent: Dict[str, str] = {}
        self.rank: Dict[str, int] = {}

    def add(self, item: str) -> None:
        if item not in self.parent:
            self.parent[item] = item
            self.rank[item] = 0

    def find(self, item: str) -> str:
        self.add(item)
        parent = self.parent[item]
        if parent != item:
            self.parent[item] = self.find(parent)
        return self.parent[item]

    def union(self, left: str, right: str) -> None:
        left_root = self.find(left)
        right_root = self.find(right)
        if left_root == right_root:
            return
        if self.rank[left_root] < self.rank[right_root]:
            left_root, right_root = right_root, left_root
        self.parent[right_root] = left_root
        if self.rank[left_root] == self.rank[right_root]:
            self.rank[left_root] += 1


# ---------------------------------------------------------------------------
# Evidence structures
# ---------------------------------------------------------------------------

@dataclass
class FormEvidence:
    text: str
    evidence_types: Set[str] = field(default_factory=set)
    sites: Set[str] = field(default_factory=set)
    languages: Set[str] = field(default_factory=set)
    page_keys: Set[Tuple[str, str]] = field(default_factory=set)
    statuses: Set[str] = field(default_factory=set)
    relation_causes: Set[str] = field(default_factory=set)
    page_attestation_count: int = 0
    definition_attestation_count: int = 0
    relation_source_count: int = 0
    relation_target_count: int = 0

    def display_rank(self) -> Tuple[int, int, int, int, int, int, str]:
        # Representative only; this is not a linguistic "canonical form".
        # Prefer actual defined headwords and explicit lemma targets.
        invalid = 1 if self.statuses & NONPLAYABLE_STATUSES else 0
        return (
            invalid,
            -self.definition_attestation_count,
            -self.relation_target_count,
            -len(self.sites),
            self.relation_source_count,
            0 if is_strict_han(self.text) else 1,
            self.text,
        )


@dataclass(frozen=True)
class MergeEdge:
    source: str
    target: str
    site: str
    pageid: str
    relation_type: str
    source_template: str
    cause: str
    raw_evidence: str


# ---------------------------------------------------------------------------
# Normalizer
# ---------------------------------------------------------------------------

class ChengyuNormalizer:
    def __init__(self, staging: Path, output: Path) -> None:
        self.staging = staging
        self.output = output

        self.pages = load_site_rows(staging, "pages")
        self.definitions = load_site_rows(staging, "definitions")
        self.pronunciations = load_site_rows(staging, "pronunciations")
        self.relations = load_site_rows(staging, "relations")
        self.sections = load_site_rows(staging, "sections")
        self.templates = load_site_rows(staging, "templates")

        self.page_index: Dict[Tuple[str, str], Dict[str, str]] = {}
        self.pron_by_page: Dict[Tuple[str, str], List[Dict[str, str]]] = defaultdict(list)
        self.relation_by_page: Dict[Tuple[str, str], List[Dict[str, str]]] = defaultdict(list)
        self.definition_by_page: Dict[Tuple[str, str], List[Dict[str, str]]] = defaultdict(list)
        self.template_by_page: Dict[Tuple[str, str], List[Dict[str, str]]] = defaultdict(list)

        self.page_forms: Dict[Tuple[str, str], List[str]] = {}
        self.page_mapping_kind: Dict[Tuple[str, str], str] = {}
        self.form_evidence: Dict[str, FormEvidence] = {}
        self.merge_edges: List[MergeEdge] = []
        self.unresolved_page_rows: List[Dict[str, str]] = []
        self.excluded_page_rows: List[Dict[str, str]] = []
        self.unresolved_form_relation_rows: List[Dict[str, str]] = []

        self.family_by_form: Dict[str, str] = {}
        self.form_id_by_text: Dict[str, str] = {}
        self.display_form_by_family: Dict[str, str] = {}

        self._index_inputs()

    def _index_inputs(self) -> None:
        for site, rows in self.pages.items():
            for row in rows:
                self.page_index[(site, row["pageid"])] = row
        for site, rows in self.pronunciations.items():
            for row in rows:
                self.pron_by_page[(site, row["pageid"])].append(row)
        for site, rows in self.relations.items():
            for row in rows:
                self.relation_by_page[(site, row["pageid"])].append(row)
        for site, rows in self.definitions.items():
            for row in rows:
                self.definition_by_page[(site, row["pageid"])].append(row)
        for site, rows in self.templates.items():
            for row in rows:
                self.template_by_page[(site, row["pageid"])].append(row)

    def evidence_for(self, form: str) -> FormEvidence:
        if form not in self.form_evidence:
            self.form_evidence[form] = FormEvidence(text=form)
        return self.form_evidence[form]

    def run(self) -> None:
        self._prepare_output()
        self._collect_page_forms()
        self._collect_merge_evidence()
        self._assemble_families()
        self._write_outputs()

    def _prepare_output(self) -> None:
        if self.output.exists():
            shutil.rmtree(self.output)
        self.output.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Page -> underlying form resolution
    # ------------------------------------------------------------------

    def _collect_page_forms(self) -> None:
        for site in SITES:
            for page in self.pages[site]:
                key = (site, page["pageid"])
                if bool_field(page.get("category_meta_term", "")):
                    self.page_forms[key] = []
                    self.page_mapping_kind[key] = "excluded_meta_term"
                    self.excluded_page_rows.append({
                        "site": site,
                        "pageid": page["pageid"],
                        "title": page["title"],
                        "reason": "category_meta_term",
                        "url": page["url"],
                    })
                    continue

                forms = self._forms_for_page(page)
                mapping_kind = self._mapping_kind_for_page(page, forms)

                if not forms:
                    # A non-Han page such as yygq may explicitly say it is an
                    # initialism of a Han Chengyu. Attach the source page to that
                    # family without turning the Latin initialism into a form.
                    derived_target = self._derived_non_han_target(page)
                    if derived_target:
                        forms = [derived_target]
                        mapping_kind = "derived_non_han_page"

                self.page_forms[key] = forms
                self.page_mapping_kind[key] = mapping_kind

                if not forms:
                    self.unresolved_page_rows.append({
                        "site": site,
                        "pageid": page["pageid"],
                        "title": page["title"],
                        "title_script": page["title_script"],
                        "reason": "no_explicit_underlying_form",
                        "source_gaps": page.get("source_gaps", ""),
                        "url": page["url"],
                    })
                    continue

                for form in forms:
                    evidence = self.evidence_for(form)
                    evidence.evidence_types.add(
                        "page_attestation" if mapping_kind == "headword"
                        else f"{mapping_kind}_attestation"
                    )
                    evidence.sites.add(site)
                    evidence.page_keys.add(key)
                    evidence.page_attestation_count += 1
                    evidence.languages.update(split_multi(page.get("attestation_tags", "")))
                    if int_field(page.get("definition_evidence_count", "")) > 0:
                        evidence.definition_attestation_count += 1

    def _mapping_kind_for_page(self, page: Dict[str, str], forms: List[str]) -> str:
        if not forms:
            return "unmapped"
        script = page.get("title_script", "")
        if script == "han" or script.startswith("han+"):
            return "headword"
        if "hangul" in script:
            return "mapped_hangul_headword"
        if any(
            row.get("relation_kind") == "pronunciation"
            for row in self.relation_by_page[(page["site"], page["pageid"])]
        ):
            return "pronunciation_page"
        return "mapped_non_han_headword"

    def _forms_for_page(self, page: Dict[str, str]) -> List[str]:
        site = page["site"]
        pageid = page["pageid"]
        title = page["title"].strip()
        script = page.get("title_script", "")

        # Han headwords, including punctuation and Japanese iteration marks, are
        # source forms exactly as written.
        if "han" in script and has_han(title):
            return [title]

        # English Wiktionary Korean Hangul headwords reliably expose the full
        # underlying Hanja in POS templates such as {{ko-noun|hanja=...}}.
        # Do not use the lossy page summary if the template is available.
        if "hangul" in script and site == "enwiktionary":
            forms: List[str] = []
            for template in self.template_by_page[(site, pageid)]:
                try:
                    args = json.loads(template.get("args_json", "") or "{}")
                except json.JSONDecodeError:
                    continue
                value = str(args.get("hanja", "") or "").strip()
                forms.extend(explicit_hanja_values(value))
            return unique(forms)

        # Korean Wiktionary's extractor emits a page-title Hangul reading whose
        # target is the explicitly stated Hanja when that mapping exists.
        if "hangul" in script and site == "kowiktionary":
            forms = [
                row["target_form"].strip()
                for row in self.pron_by_page[(site, pageid)]
                if row.get("source_template") == "page_title"
                and has_han(row.get("target_form", ""))
            ]
            return unique(forms)

        # Romanized zh-see|...|poj pages are pronunciation attestations of their
        # Han target, not separate lexical forms.
        pronunciation_targets = [
            row["target_form"].strip()
            for row in self.relation_by_page[(site, pageid)]
            if row.get("relation_kind") == "pronunciation"
            and has_han(row.get("target_form", ""))
        ]
        if pronunciation_targets:
            return unique(pronunciation_targets)

        # As a final source-evidence fallback, only use an explicit Hanja field
        # when it contains a single unambiguous form.
        explicit_hanja = [form for form in split_multi(page.get("explicit_hanja", "")) if has_han(form)]
        if len(explicit_hanja) == 1:
            return explicit_hanja

        return []

    # ------------------------------------------------------------------
    # Family merge graph
    # ------------------------------------------------------------------

    def _collect_merge_evidence(self) -> None:
        self._collect_same_page_hanja_relations()
        self._collect_korean_lexeme_bridges()
        self._collect_cjkv_form_relations()

        # Structured headword templates carry a large amount of explicit
        # orthographic evidence that never becomes a zh-see redirect.
        self._collect_headword_template_form_relations()

        # zh-see / ja-see form redirects.
        for site in SITES:
            for row in self.relations[site]:
                source = row.get("source_form", "").strip()
                target = row.get("target_form", "").strip()
                if row.get("relation_kind") != "variant":
                    # Pronunciation targets still establish an underlying form.
                    if row.get("relation_kind") == "pronunciation" and target and has_han(target):
                        evidence = self.evidence_for(target)
                        evidence.evidence_types.add("pronunciation_target")
                        evidence.sites.add(site)
                    continue
                if not (source and target and has_han(source) and has_han(target)):
                    continue
                source_evidence = self.evidence_for(source)
                target_evidence = self.evidence_for(target)
                source_evidence.evidence_types.add("variant_relation_source")
                target_evidence.evidence_types.add("variant_relation_target")
                source_evidence.sites.add(site)
                target_evidence.sites.add(site)
                source_evidence.statuses.add("nonlemma_variant")
                if row.get("relation_cause"):
                    source_evidence.relation_causes.add(row["relation_cause"])
                source_evidence.relation_source_count += 1
                target_evidence.relation_target_count += 1
                self.merge_edges.append(MergeEdge(
                    source=source,
                    target=target,
                    site=site,
                    pageid=row["pageid"],
                    relation_type="variant",
                    source_template=row.get("relation_template", ""),
                    cause=row.get("relation_cause", ""),
                    raw_evidence=row.get("relation_type_code", ""),
                ))

        # Definition templates that explicitly say "alternative/misspelling/etc. form of".
        for site in SITES:
            for row in self.definitions[site]:
                relation_type = row.get("relation_type", "")
                if relation_type not in JOINABLE_DEFINITION_RELATIONS:
                    continue
                source = row.get("title", "").strip()
                targets = explicit_relation_targets(row.get("relation_target", ""))
                if not (source and has_han(source) and targets):
                    self.unresolved_form_relation_rows.append({
                        "site": site,
                        "pageid": row.get("pageid", ""),
                        "title": source,
                        "relation_type": relation_type,
                        "raw_evidence": row.get("raw_definition", ""),
                        "reason": "missing_or_non_han_target",
                    })
                    continue
                for target in targets:
                    source_evidence = self.evidence_for(source)
                    target_evidence = self.evidence_for(target)
                    source_evidence.evidence_types.add(f"{relation_type}_source")
                    target_evidence.evidence_types.add(f"{relation_type}_target")
                    source_evidence.sites.add(site)
                    target_evidence.sites.add(site)
                    source_evidence.statuses.add(JOINABLE_DEFINITION_RELATIONS[relation_type])
                    source_evidence.relation_source_count += 1
                    target_evidence.relation_target_count += 1
                    self.merge_edges.append(MergeEdge(
                        source=source,
                        target=target,
                        site=site,
                        pageid=row["pageid"],
                        relation_type=relation_type,
                        source_template=row.get("relation_template", ""),
                        cause="",
                        raw_evidence=row.get("raw_definition", ""),
                    ))

        # zh-erhua form-of is only safe when Wiktionary supplies an explicit
        # |word= target. Positional args in this template are usually glosses.
        for site in SITES:
            for row in self.templates[site]:
                if row.get("template_name", "").strip().lower() not in {
                    "zh-erhua form of", "zh-erhua form-of"
                }:
                    continue
                try:
                    args = json.loads(row.get("args_json", "") or "{}")
                except json.JSONDecodeError:
                    args = {}
                source = row.get("title", "").strip()
                target = str(args.get("word", "") or "").strip()
                if not target:
                    self.unresolved_form_relation_rows.append({
                        "site": site,
                        "pageid": row.get("pageid", ""),
                        "title": source,
                        "relation_type": "erhua_form_of",
                        "raw_evidence": row.get("raw_template", ""),
                        "reason": "no_explicit_word_target",
                    })
                    continue
                if not (has_han(source) and has_han(target)):
                    self.unresolved_form_relation_rows.append({
                        "site": site,
                        "pageid": row.get("pageid", ""),
                        "title": source,
                        "relation_type": "erhua_form_of",
                        "raw_evidence": row.get("raw_template", ""),
                        "reason": "non_han_explicit_word_target",
                    })
                    continue
                source_evidence = self.evidence_for(source)
                target_evidence = self.evidence_for(target)
                source_evidence.evidence_types.add("erhua_form_of_source")
                target_evidence.evidence_types.add("erhua_form_of_target")
                source_evidence.sites.add(site)
                target_evidence.sites.add(site)
                source_evidence.statuses.add("erhua_form")
                source_evidence.relation_source_count += 1
                target_evidence.relation_target_count += 1
                self.merge_edges.append(MergeEdge(
                    source=source,
                    target=target,
                    site=site,
                    pageid=row["pageid"],
                    relation_type="erhua_form_of",
                    source_template=row.get("template_name", ""),
                    cause="explicit_word_parameter",
                    raw_evidence=row.get("raw_template", ""),
                ))


    def _collect_korean_lexeme_bridges(self) -> None:
        """Merge Hanja forms only when Wiktionary gives a two-way Korean lexeme bridge.

        A Hangul headword page can explicitly map to Hanja Z, while a Han-script
        page can explicitly say it is the Hanja form of the same Hangul lexeme Y.
        That is stronger than merely sharing a pronunciation: both source pages
        identify the same Korean lexical entry.  We require the Hangul headword
        page as an anchor so homophonous Hangul readings alone never merge forms.
        """
        anchors: Dict[str, Set[str]] = defaultdict(set)
        for (site, pageid), forms in self.page_forms.items():
            if self.page_mapping_kind.get((site, pageid)) != "mapped_hangul_headword":
                continue
            page = self.page_index.get((site, pageid), {})
            hangul = (page.get("title", "") or "").strip()
            if not hangul or "hangul" not in (page.get("title_script", "") or ""):
                continue
            anchors[hangul].update(form for form in forms if is_strict_han(form))

        if not anchors:
            return

        pointed: Dict[str, Set[Tuple[str, str, str]]] = defaultdict(set)
        for site in SITES:
            for row in self.definitions[site]:
                if row.get("relation_type") != "hanja_form_of" or row.get("relation_language") != "ko":
                    continue
                source = (row.get("title", "") or "").strip()
                hangul = (row.get("relation_target", "") or "").strip()
                if hangul not in anchors or not is_strict_han(source):
                    continue
                pointed[hangul].add((source, site, row.get("pageid", "")))

        for hangul, anchor_forms in anchors.items():
            if not anchor_forms:
                continue
            anchor = sorted(anchor_forms)[0]
            for source, site, pageid in sorted(pointed.get(hangul, set())):
                if source == anchor:
                    continue
                source_evidence = self.evidence_for(source)
                anchor_evidence = self.evidence_for(anchor)
                source_evidence.evidence_types.add("korean_lexeme_bridge_source")
                anchor_evidence.evidence_types.add("korean_lexeme_bridge_target")
                source_evidence.sites.add(site)
                source_evidence.statuses.add("korean_hanja_variant")
                source_evidence.relation_source_count += 1
                anchor_evidence.relation_target_count += 1
                self.merge_edges.append(MergeEdge(
                    source=source,
                    target=anchor,
                    site=site,
                    pageid=pageid,
                    relation_type="same_korean_lexeme_hanja",
                    source_template="hanja form of + mapped Hangul headword",
                    cause=f"hangul={hangul}",
                    raw_evidence=hangul,
                ))

    def _collect_cjkv_form_relations(self) -> None:
        """Use explicit Han-script forms listed by Wiktionary's CJKV descendants table.

        CJKV is source-declared Sino-Xenic descendant evidence.  Only Han-only
        written forms are family-merged here; kana, Hangul and romanization stay
        readings rather than becoming Chengyu forms.
        """
        form_keys = ("1", "j", "j2", "s", "k", "k2", "h", "v")
        for site in SITES:
            for row in self.templates[site]:
                if row.get("template_name", "").strip().lower() != "cjkv":
                    continue
                source = (row.get("title", "") or "").strip()
                if not is_strict_han(source):
                    continue
                try:
                    args = json.loads(row.get("args_json", "") or "{}")
                except json.JSONDecodeError:
                    args = {}
                for key in form_keys:
                    candidate = clean_cjkv_value(str(args.get(key, "") or ""))
                    if not candidate or candidate == source or not is_strict_han(candidate):
                        continue
                    source_evidence = self.evidence_for(candidate)
                    target_evidence = self.evidence_for(source)
                    source_evidence.evidence_types.add("cjkv_descendant_form_source")
                    target_evidence.evidence_types.add("cjkv_descendant_form_target")
                    source_evidence.sites.add(site)
                    target_evidence.sites.add(site)
                    source_evidence.statuses.add("sino_xenic_variant")
                    source_evidence.relation_causes.add(f"argument={key}")
                    source_evidence.relation_source_count += 1
                    target_evidence.relation_target_count += 1
                    self.merge_edges.append(MergeEdge(
                        source=candidate,
                        target=source,
                        site=site,
                        pageid=row.get("pageid", ""),
                        relation_type="sino_xenic_form",
                        source_template=row.get("template_name", ""),
                        cause=f"argument={key}",
                        raw_evidence=row.get("raw_template", ""),
                    ))

    def _collect_same_page_hanja_relations(self) -> None:
        # A Hangul headword may explicitly supply more than one Hanja spelling.
        # Those spellings are source-declared alternatives of the same Korean
        # lexical item, so this is a safe family merge.
        for (site, pageid), forms in self.page_forms.items():
            if len(forms) < 2:
                continue
            if self.page_mapping_kind.get((site, pageid)) != "mapped_hangul_headword":
                continue
            base = forms[0]
            for variant in forms[1:]:
                variant_evidence = self.evidence_for(variant)
                base_evidence = self.evidence_for(base)
                variant_evidence.statuses.add("korean_hanja_variant")
                variant_evidence.evidence_types.add("same_hangul_headword_variant")
                base_evidence.evidence_types.add("same_hangul_headword_base")
                variant_evidence.relation_source_count += 1
                base_evidence.relation_target_count += 1
                self.merge_edges.append(MergeEdge(
                    source=variant,
                    target=base,
                    site=site,
                    pageid=pageid,
                    relation_type="same_hangul_headword_hanja",
                    source_template="hanja=",
                    cause="same_source_headword",
                    raw_evidence="",
                ))

    def _collect_headword_template_form_relations(self) -> None:
        for site in SITES:
            for row in self.templates[site]:
                name = row.get("template_name", "").strip().lower()
                source = row.get("title", "").strip()
                if not source or not has_han(source):
                    continue
                try:
                    args = json.loads(row.get("args_json", "") or "{}")
                except json.JSONDecodeError:
                    args = {}

                variants: List[Tuple[str, str, str]] = []

                if name == "zh-forms":
                    for key, status in (
                        ("s", "simplified"),
                        ("s2", "simplified"),
                        ("t2", "traditional_variant"),
                        ("t3", "traditional_variant"),
                        ("t4", "traditional_variant"),
                        ("ns", "nonstandard_simplified"),
                        ("ss", "explicit_variant"),
                    ):
                        value = str(args.get(key, "") or "")
                        for target, qualifier in explicit_form_values(value, split_list=False):
                            variants.append((target, status, qualifier or f"argument={key}"))
                    for target, qualifier in explicit_form_values(
                        str(args.get("alt", "") or ""), split_list=True
                    ):
                        variants.append((target, qualifier_status(qualifier), qualifier or "argument=alt"))

                elif name == "ja-kanjitab":
                    for target, qualifier in explicit_form_values(
                        str(args.get("alt", "") or ""), split_list=True
                    ):
                        variants.append((target, qualifier_status(qualifier), qualifier or "argument=alt"))

                elif name == "ja-gv":
                    target = clean_cjkv_value(str(args.get("1", "") or ""))
                    if target:
                        variants.append((target, "japanese_glyph_variant", "argument=1"))

                for variant, status, qualifier in variants:
                    if not variant or variant == source or not has_han(variant):
                        continue
                    variant_evidence = self.evidence_for(variant)
                    source_evidence = self.evidence_for(source)
                    variant_evidence.evidence_types.add(f"{name}_variant_source")
                    source_evidence.evidence_types.add(f"{name}_variant_target")
                    variant_evidence.sites.add(site)
                    source_evidence.sites.add(site)
                    variant_evidence.statuses.add(status)
                    if qualifier:
                        variant_evidence.relation_causes.add(qualifier)
                    variant_evidence.relation_source_count += 1
                    source_evidence.relation_target_count += 1
                    self.merge_edges.append(MergeEdge(
                        source=variant,
                        target=source,
                        site=site,
                        pageid=row.get("pageid", ""),
                        relation_type="explicit_headword_variant",
                        source_template=row.get("template_name", ""),
                        cause=qualifier,
                        raw_evidence=row.get("raw_template", ""),
                    ))

    def _assemble_families(self) -> None:
        union = UnionFind()
        for form in self.form_evidence:
            union.add(form)
        for edge in self.merge_edges:
            union.union(edge.source, edge.target)

        components: Dict[str, List[str]] = defaultdict(list)
        for form in self.form_evidence:
            components[union.find(form)].append(form)

        component_rows: List[Tuple[str, List[str]]] = []
        for forms in components.values():
            display = min(forms, key=lambda form: self.form_evidence[form].display_rank())
            component_rows.append((display, sorted(forms)))
        component_rows.sort(key=lambda pair: (pair[0], pair[1]))

        form_serial = 1
        for family_serial, (display, forms) in enumerate(component_rows, start=1):
            family_id = f"F{family_serial:06d}"
            self.display_form_by_family[family_id] = display
            for form in forms:
                self.family_by_form[form] = family_id
            for form in sorted(forms):
                self.form_id_by_text[form] = f"FORM{form_serial:06d}"
                form_serial += 1

    # ------------------------------------------------------------------
    # Output construction
    # ------------------------------------------------------------------

    def _write_outputs(self) -> None:
        families = self._family_rows()
        forms = self._form_rows()
        attestations = self._attestation_rows()
        readings = self._reading_rows()
        senses = self._sense_rows()
        etymologies = self._etymology_rows()
        provenances = self._provenance_rows()
        form_relations = self._form_relation_rows()
        semantic_relations = self._semantic_relation_rows()

        write_csv(self.output / "families.csv", [
            "family_id", "display_form", "form_count", "site_count", "language_count",
            "attestation_count", "definition_attestation_count", "reading_count",
            "sense_count", "etymology_count", "strict_han_form_count",
        ], families)
        write_csv(self.output / "forms.csv", [
            "form_id", "family_id", "form_text", "is_display_form", "script_class",
            "codepoint_length", "han_character_count", "is_strict_han",
            "contains_punctuation", "statuses", "relation_causes", "evidence_types",
            "sites", "languages", "page_attestation_count",
            "definition_attestation_count", "relation_source_count", "relation_target_count",
        ], forms)
        write_csv(self.output / "attestations.csv", [
            "attestation_id", "family_id", "form_id", "form_text", "site", "pageid",
            "page_title", "entry_language_tag", "entry_language_source",
            "attestation_kind", "source_keys", "source_categories", "categories",
            "revision_id", "revision_timestamp", "revision_sha1", "url",
            "has_definition_evidence", "source_gaps",
        ], attestations)
        write_csv(self.output / "readings.csv", [
            "reading_id", "family_id", "form_id", "target_form", "reading",
            "language_tag", "language_label", "system", "system_label", "site",
            "pageid", "page_title", "source_template", "source_type_code", "url",
        ], readings)
        write_csv(self.output / "senses.csv", [
            "sense_id", "family_id", "form_id", "form_text", "site", "pageid",
            "page_title", "entry_language_tag", "definition_language_tag",
            "heading_path", "section_kind", "plain_definition", "raw_definition",
        ], senses)
        write_csv(self.output / "etymologies.csv", [
            "etymology_id", "family_id", "form_id", "form_text", "site", "pageid",
            "page_title", "entry_language_tag", "definition_language_tag",
            "heading_path", "plain_text", "raw_wikitext",
        ], etymologies)
        write_csv(self.output / "provenances.csv", [
            "provenance_id", "family_id", "form_id", "form_text", "site", "pageid",
            "page_title", "source_category", "source_title", "url",
        ], provenances)
        write_csv(self.output / "form_relations.csv", [
            "relation_id", "family_id", "source_form_id", "source_form",
            "target_form_id", "target_form", "relation_type", "site", "pageid",
            "source_template", "cause", "raw_evidence", "merge_policy",
        ], form_relations)
        write_csv(self.output / "semantic_relations.csv", [
            "relation_id", "source_family_id", "source_form_id", "source_form",
            "target_family_id", "target_form_id", "target_text", "relation_type",
            "relation_language", "site", "pageid", "page_title", "source_template",
            "raw_definition", "merge_policy",
        ], semantic_relations)

        self._write_diagnostics(
            families=families,
            forms=forms,
            attestations=attestations,
            readings=readings,
            senses=senses,
            etymologies=etymologies,
            provenances=provenances,
            form_relations=form_relations,
            semantic_relations=semantic_relations,
        )

    def _family_rows(self) -> List[Dict[str, object]]:
        by_family: Dict[str, List[str]] = defaultdict(list)
        for form, family_id in self.family_by_form.items():
            by_family[family_id].append(form)

        # Precompute counts from downstream source evidence without needing output IDs.
        page_attestations_by_family: Counter[str] = Counter()
        language_by_family: Dict[str, Set[str]] = defaultdict(set)
        site_by_family: Dict[str, Set[str]] = defaultdict(set)
        for form, family_id in self.family_by_form.items():
            ev = self.form_evidence[form]
            page_attestations_by_family[family_id] += ev.page_attestation_count
            language_by_family[family_id].update(ev.languages)
            site_by_family[family_id].update(ev.sites)

        reading_counts: Counter[str] = Counter()
        for row in self._reading_rows(assign_ids=False):
            reading_counts[row["family_id"]] += 1
        sense_counts: Counter[str] = Counter()
        for row in self._sense_rows(assign_ids=False):
            sense_counts[row["family_id"]] += 1
        etym_counts: Counter[str] = Counter()
        for row in self._etymology_rows(assign_ids=False):
            etym_counts[row["family_id"]] += 1

        rows: List[Dict[str, object]] = []
        for family_id in sorted(by_family):
            forms = by_family[family_id]
            rows.append({
                "family_id": family_id,
                "display_form": self.display_form_by_family[family_id],
                "form_count": len(forms),
                "site_count": len(site_by_family[family_id]),
                "language_count": len(language_by_family[family_id]),
                "attestation_count": page_attestations_by_family[family_id],
                "definition_attestation_count": sum(
                    self.form_evidence[form].definition_attestation_count for form in forms
                ),
                "reading_count": reading_counts[family_id],
                "sense_count": sense_counts[family_id],
                "etymology_count": etym_counts[family_id],
                "strict_han_form_count": sum(1 for form in forms if is_strict_han(form)),
            })
        return rows

    def _form_rows(self) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        for form in sorted(self.family_by_form, key=lambda text: self.form_id_by_text[text]):
            ev = self.form_evidence[form]
            family_id = self.family_by_form[form]
            rows.append({
                "form_id": self.form_id_by_text[form],
                "family_id": family_id,
                "form_text": form,
                "is_display_form": form == self.display_form_by_family[family_id],
                "script_class": classify_form(form),
                "codepoint_length": len(form),
                "han_character_count": han_count(form),
                "is_strict_han": is_strict_han(form),
                "contains_punctuation": contains_punctuation(form),
                "statuses": sorted(ev.statuses),
                "relation_causes": sorted(ev.relation_causes),
                "evidence_types": sorted(ev.evidence_types),
                "sites": sorted(ev.sites),
                "languages": sorted(ev.languages),
                "page_attestation_count": ev.page_attestation_count,
                "definition_attestation_count": ev.definition_attestation_count,
                "relation_source_count": ev.relation_source_count,
                "relation_target_count": ev.relation_target_count,
            })
        return rows

    def _attestation_rows(self) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        seen: Set[Tuple[str, ...]] = set()

        for site in SITES:
            for page in self.pages[site]:
                key = (site, page["pageid"])
                forms = self.page_forms.get(key, [])
                kind = self.page_mapping_kind.get(key, "headword")
                if not forms:
                    continue

                language_sources: Dict[str, Set[str]] = defaultdict(set)
                for tag in split_multi(page.get("language_tags", "")):
                    language_sources[tag].add("heading")
                for tag in split_multi(page.get("category_language_tags", "")):
                    language_sources[tag].add("category")
                if not language_sources:
                    for tag in split_multi(page.get("attestation_tags", "")):
                        language_sources[tag].add("page")

                if kind in {"pronunciation_page", "mapped_non_han_headword"}:
                    # POJ and similar pages should use the reading's actual language tag,
                    # not broad Chinese category inheritance.
                    pron_tags = {
                        row.get("language_tag", "")
                        for row in self.pron_by_page[key]
                        if row.get("language_tag", "")
                    }
                    if pron_tags:
                        language_sources = defaultdict(set, {tag: {"pronunciation"} for tag in pron_tags})

                if not language_sources:
                    language_sources[""] = {"page"}

                for form in forms:
                    if form not in self.family_by_form:
                        continue
                    for language_tag in sorted(language_sources):
                        dedupe = (site, page["pageid"], form, language_tag, kind)
                        if dedupe in seen:
                            continue
                        seen.add(dedupe)
                        rows.append({
                            "family_id": self.family_by_form[form],
                            "form_id": self.form_id_by_text[form],
                            "form_text": form,
                            "site": site,
                            "pageid": page["pageid"],
                            "page_title": page["title"],
                            "entry_language_tag": language_tag,
                            "entry_language_source": "+".join(sorted(language_sources[language_tag])),
                            "attestation_kind": kind,
                            "source_keys": page.get("source_keys", ""),
                            "source_categories": page.get("source_categories", ""),
                            "categories": page.get("categories", ""),
                            "revision_id": page.get("revision_id", ""),
                            "revision_timestamp": page.get("revision_timestamp", ""),
                            "revision_sha1": page.get("revision_sha1", ""),
                            "url": page.get("url", ""),
                            "has_definition_evidence": int_field(page.get("definition_evidence_count", "")) > 0,
                            "source_gaps": page.get("source_gaps", ""),
                        })

        rows.sort(key=lambda row: (
            row["family_id"], row["form_id"], row["site"], int_field(row["pageid"]),
            row["entry_language_tag"], row["attestation_kind"],
        ))
        for index, row in enumerate(rows, start=1):
            row["attestation_id"] = f"A{index:07d}"
        return rows

    def _derived_non_han_target(self, page: Dict[str, str]) -> str:
        key = (page["site"], page["pageid"])
        candidates = []
        for row in self.definition_by_page[key]:
            if row.get("relation_type") in {"initialism_of"}:
                target = row.get("relation_target", "").strip()
                if target and has_han(target):
                    candidates.append(target)
        candidates = unique(candidates)
        return candidates[0] if len(candidates) == 1 else ""

    def _reading_rows(self, assign_ids: bool = True) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        seen: Set[Tuple[str, ...]] = set()

        def add(
            *,
            target: str,
            reading: str,
            language_tag: str,
            language_label: str,
            system: str,
            system_label: str,
            site: str,
            pageid: str,
            page_title: str,
            source_template: str,
            source_type_code: str,
            url: str,
        ) -> None:
            if not (target and reading and target in self.family_by_form):
                return
            key = (target, reading, language_tag, system, site, pageid)
            if key in seen:
                return
            seen.add(key)
            rows.append({
                "family_id": self.family_by_form[target],
                "form_id": self.form_id_by_text[target],
                "target_form": target,
                "reading": reading,
                "language_tag": language_tag,
                "language_label": language_label,
                "system": system,
                "system_label": system_label,
                "site": site,
                "pageid": pageid,
                "page_title": page_title,
                "source_template": source_template,
                "source_type_code": source_type_code,
                "url": url,
            })

        # Scraper-extracted pronunciations.
        for site in SITES:
            for row in self.pronunciations[site]:
                target = row.get("target_form", "").strip()
                reading = row.get("reading", "").strip()
                # page_title Korean rows with a Hangul target are an input event, not
                # an underlying Han form; the Hanja-target rows are handled normally.
                add(
                    target=target,
                    reading=reading,
                    language_tag=row.get("language_tag", ""),
                    language_label=row.get("language_label", ""),
                    system=row.get("system", ""),
                    system_label=row.get("system_label", ""),
                    site=site,
                    pageid=row.get("pageid", ""),
                    page_title=row.get("title", ""),
                    source_template=row.get("source_template", ""),
                    source_type_code=row.get("source_type_code", ""),
                    url=row.get("url", ""),
                )

        # Definition templates can carry orthographic readings not yet emitted by
        # the pronunciation extractor, notably Vietnamese Han-form relations.
        for site in SITES:
            for row in self.definitions[site]:
                relation_type = row.get("relation_type", "")
                language = row.get("relation_language", "")
                system_info = READING_RELATION_SYSTEMS.get((relation_type, language))
                if not system_info:
                    continue
                source = row.get("title", "").strip()
                reading = row.get("relation_target", "").strip()
                if not (source in self.family_by_form and reading):
                    continue
                system, label = system_info
                add(
                    target=source,
                    reading=reading,
                    language_tag=language,
                    language_label={"ko": "Korean", "vi": "Vietnamese"}.get(language, language),
                    system=system,
                    system_label=label,
                    site=site,
                    pageid=row.get("pageid", ""),
                    page_title=row.get("title", ""),
                    source_template=row.get("relation_template", ""),
                    source_type_code="",
                    url=self.page_index.get((site, row.get("pageid", "")), {}).get("url", ""),
                )

        # CJKV descendant tables carry explicit Sino-Xenic readings even when
        # the descendant has no separate page in our harvested categories.
        for site in SITES:
            for row in self.templates[site]:
                if row.get("template_name", "").strip().lower() != "cjkv":
                    continue
                source = (row.get("title", "") or "").strip()
                if source not in self.family_by_form:
                    continue
                try:
                    args = json.loads(row.get("args_json", "") or "{}")
                except json.JSONDecodeError:
                    args = {}

                def first_han(keys: Sequence[str]) -> str:
                    for key in keys:
                        candidate = clean_cjkv_value(str(args.get(key, "") or ""))
                        if candidate in self.family_by_form and is_strict_han(candidate):
                            return candidate
                    return source

                ja_reading = clean_cjkv_reading(str(args.get("2", "") or ""))
                if ja_reading:
                    add(
                        target=first_han(("j", "s", "1", "j2")),
                        reading=ja_reading, language_tag="ja", language_label="Japanese",
                        system="kana", system_label="Kana", site=site,
                        pageid=row.get("pageid", ""), page_title=source,
                        source_template=row.get("template_name", ""), source_type_code="2",
                        url=self.page_index.get((site, row.get("pageid", "")), {}).get("url", ""),
                    )

                ko_reading = clean_cjkv_reading(str(args.get("3", "") or ""))
                if ko_reading:
                    add(
                        target=first_han(("k", "h", "k2")),
                        reading=ko_reading, language_tag="ko", language_label="Korean",
                        system="hangul", system_label="Hangul", site=site,
                        pageid=row.get("pageid", ""), page_title=source,
                        source_template=row.get("template_name", ""), source_type_code="3",
                        url=self.page_index.get((site, row.get("pageid", "")), {}).get("url", ""),
                    )

                vi_reading = clean_cjkv_reading(str(args.get("4", "") or ""))
                if vi_reading:
                    add(
                        target=first_han(("v",)),
                        reading=vi_reading, language_tag="vi", language_label="Vietnamese",
                        system="sino_vietnamese", system_label="Sino-Vietnamese", site=site,
                        pageid=row.get("pageid", ""), page_title=source,
                        source_template=row.get("template_name", ""), source_type_code="4",
                        url=self.page_index.get((site, row.get("pageid", "")), {}).get("url", ""),
                    )

        rows.sort(key=lambda row: (
            row["family_id"], row["form_id"], row["language_tag"], row["system"],
            row["reading"], row["site"], int_field(row["pageid"]),
        ))
        if assign_ids:
            for index, row in enumerate(rows, start=1):
                row["reading_id"] = f"R{index:07d}"
        return rows

    def _sense_rows(self, assign_ids: bool = True) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        seen: Set[Tuple[str, ...]] = set()
        for site in SITES:
            definition_language = DEFINITION_LANGUAGE_BY_SITE[site]
            for row in self.definitions[site]:
                plain = row.get("plain_definition", "").strip()
                if not meaningful_plain_text(plain):
                    continue
                page_key = (site, row["pageid"])
                forms = self.page_forms.get(page_key, [])
                if not forms:
                    target = self._derived_non_han_target(self.page_index.get(page_key, {}))
                    forms = [target] if target else []
                for form in forms:
                    if form not in self.family_by_form:
                        continue
                    key = (
                        site, row["pageid"], form, row.get("language_tag", ""), plain,
                    )
                    if key in seen:
                        continue
                    seen.add(key)
                    rows.append({
                        "family_id": self.family_by_form[form],
                        "form_id": self.form_id_by_text[form],
                        "form_text": form,
                        "site": site,
                        "pageid": row["pageid"],
                        "page_title": row.get("title", ""),
                        "entry_language_tag": row.get("language_tag", ""),
                        "definition_language_tag": definition_language,
                        "heading_path": row.get("heading_path", ""),
                        "section_kind": row.get("section_kind", ""),
                        "plain_definition": plain,
                        "raw_definition": row.get("raw_definition", ""),
                    })
        rows.sort(key=lambda row: (
            row["family_id"], row["form_id"], row["site"], int_field(row["pageid"]),
            row["entry_language_tag"], row["heading_path"], row["plain_definition"],
        ))
        if assign_ids:
            for index, row in enumerate(rows, start=1):
                row["sense_id"] = f"S{index:07d}"
        return rows

    def _etymology_rows(self, assign_ids: bool = True) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        seen: Set[Tuple[str, ...]] = set()
        for site in SITES:
            definition_language = DEFINITION_LANGUAGE_BY_SITE[site]
            for row in self.sections[site]:
                if row.get("section_kind") != "etymology":
                    continue
                raw = row.get("raw_wikitext", "").strip()
                plain = row.get("plain_text", "").strip()
                if not raw and not plain:
                    continue
                page_key = (site, row["pageid"])
                forms = self.page_forms.get(page_key, [])
                for form in forms:
                    if form not in self.family_by_form:
                        continue
                    key = (
                        site, row["pageid"], form, row.get("language_tag", ""),
                        row.get("heading_path", ""), raw,
                    )
                    if key in seen:
                        continue
                    seen.add(key)
                    rows.append({
                        "family_id": self.family_by_form[form],
                        "form_id": self.form_id_by_text[form],
                        "form_text": form,
                        "site": site,
                        "pageid": row["pageid"],
                        "page_title": row.get("title", ""),
                        "entry_language_tag": row.get("language_tag", ""),
                        "definition_language_tag": definition_language,
                        "heading_path": row.get("heading_path", ""),
                        "plain_text": plain,
                        "raw_wikitext": raw,
                    })
        rows.sort(key=lambda row: (
            row["family_id"], row["form_id"], row["site"], int_field(row["pageid"]),
            row["entry_language_tag"], row["heading_path"],
        ))
        if assign_ids:
            for index, row in enumerate(rows, start=1):
                row["etymology_id"] = f"E{index:07d}"
        return rows

    def _provenance_rows(self) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        seen: Set[Tuple[str, ...]] = set()
        for site in SITES:
            for page in self.pages[site]:
                forms = self.page_forms.get((site, page["pageid"]), [])
                if not forms:
                    continue
                for category in split_multi(page.get("provenance_categories", "")):
                    source_title = provenance_source_title(category)
                    for form in forms:
                        if form not in self.family_by_form:
                            continue
                        key = (site, page["pageid"], form, category)
                        if key in seen:
                            continue
                        seen.add(key)
                        rows.append({
                            "family_id": self.family_by_form[form],
                            "form_id": self.form_id_by_text[form],
                            "form_text": form,
                            "site": site,
                            "pageid": page["pageid"],
                            "page_title": page["title"],
                            "source_category": category,
                            "source_title": source_title,
                            "url": page.get("url", ""),
                        })
        rows.sort(key=lambda row: (
            row["family_id"], row["form_id"], row["site"], int_field(row["pageid"]),
            row["source_category"],
        ))
        for index, row in enumerate(rows, start=1):
            row["provenance_id"] = f"P{index:07d}"
        return rows

    def _form_relation_rows(self) -> List[Dict[str, object]]:
        rows = []
        for index, edge in enumerate(sorted(
            self.merge_edges,
            key=lambda edge: (
                self.family_by_form[edge.source], edge.source, edge.target,
                edge.site, int_field(edge.pageid), edge.relation_type,
            ),
        ), start=1):
            rows.append({
                "relation_id": f"FR{index:07d}",
                "family_id": self.family_by_form[edge.source],
                "source_form_id": self.form_id_by_text[edge.source],
                "source_form": edge.source,
                "target_form_id": self.form_id_by_text[edge.target],
                "target_form": edge.target,
                "relation_type": edge.relation_type,
                "site": edge.site,
                "pageid": edge.pageid,
                "source_template": edge.source_template,
                "cause": edge.cause,
                "raw_evidence": edge.raw_evidence,
                "merge_policy": "family_merge",
            })
        return rows

    def _semantic_relation_rows(self) -> List[Dict[str, object]]:
        rows: List[Dict[str, object]] = []
        seen: Set[Tuple[str, ...]] = set()
        nonmerge_types = {
            "synonym_of", "short_for", "initialism_of",
            "hanja_form_of", "han_form_of",
        }
        # Joinable types are already represented in form_relations.csv.
        for site in SITES:
            for row in self.definitions[site]:
                relation_type = row.get("relation_type", "")
                if not relation_type or relation_type in JOINABLE_DEFINITION_RELATIONS or relation_type == "erhua_form_of":
                    continue
                page_key = (site, row["pageid"])
                source_forms = self.page_forms.get(page_key, [])
                if not source_forms:
                    # yygq-like pages: source is non-Han, so preserve the literal page
                    # title as source_text while attaching target family if known.
                    source_forms = []
                target_text = row.get("relation_target", "").strip()

                if source_forms:
                    source_items = [(form, self.family_by_form.get(form, "")) for form in source_forms]
                else:
                    source_items = [(row.get("title", ""), "")]

                for source_text, source_family in source_items:
                    target_family = self.family_by_form.get(target_text, "")
                    target_form_id = self.form_id_by_text.get(target_text, "")
                    source_form_id = self.form_id_by_text.get(source_text, "")
                    key = (
                        site, row["pageid"], source_text, target_text, relation_type,
                        row.get("raw_definition", ""),
                    )
                    if key in seen:
                        continue
                    seen.add(key)
                    rows.append({
                        "source_family_id": source_family,
                        "source_form_id": source_form_id,
                        "source_form": source_text,
                        "target_family_id": target_family,
                        "target_form_id": target_form_id,
                        "target_text": target_text,
                        "relation_type": relation_type,
                        "relation_language": row.get("relation_language", ""),
                        "site": site,
                        "pageid": row["pageid"],
                        "page_title": row.get("title", ""),
                        "source_template": row.get("relation_template", ""),
                        "raw_definition": row.get("raw_definition", ""),
                        "merge_policy": "reading_only" if relation_type in {"hanja_form_of", "han_form_of"} else "keep_separate",
                    })

        rows.sort(key=lambda row: (
            row["source_family_id"], row["source_form"], row["relation_type"],
            row["target_text"], row["site"], int_field(row["pageid"]),
        ))
        for index, row in enumerate(rows, start=1):
            row["relation_id"] = f"SR{index:07d}"
        return rows

    # ------------------------------------------------------------------
    # Diagnostics
    # ------------------------------------------------------------------

    def _write_diagnostics(self, **tables: List[Dict[str, object]]) -> None:
        diagnostics = self.output / "diagnostics"
        diagnostics.mkdir(parents=True, exist_ok=True)

        write_csv(diagnostics / "unmapped_pages.csv", [
            "site", "pageid", "title", "title_script", "reason", "source_gaps", "url",
        ], sorted(self.unresolved_page_rows, key=lambda row: (
            row["site"], int_field(row["pageid"]), row["title"]
        )))
        write_csv(diagnostics / "excluded_meta_terms.csv", [
            "site", "pageid", "title", "reason", "url",
        ], self.excluded_page_rows)
        write_csv(diagnostics / "unresolved_form_relations.csv", [
            "site", "pageid", "title", "relation_type", "raw_evidence", "reason",
        ], self.unresolved_form_relation_rows)

        families = tables["families"]
        forms = tables["forms"]

        large_family_rows = []
        forms_by_family: Dict[str, List[str]] = defaultdict(list)
        for row in forms:
            forms_by_family[str(row["family_id"])].append(str(row["form_text"]))
        for family in families:
            family_id = str(family["family_id"])
            if int(family["form_count"]) >= 6:
                large_family_rows.append({
                    "family_id": family_id,
                    "display_form": family["display_form"],
                    "form_count": family["form_count"],
                    "forms": sorted(forms_by_family[family_id]),
                })
        write_csv(diagnostics / "large_families.csv", [
            "family_id", "display_form", "form_count", "forms",
        ], large_family_rows)

        ambiguous_sources: Dict[str, Set[str]] = defaultdict(set)
        for edge in self.merge_edges:
            ambiguous_sources[edge.source].add(edge.target)
        ambiguity_rows = []
        for source, targets in sorted(ambiguous_sources.items()):
            if len(targets) <= 1:
                continue
            ambiguity_rows.append({
                "source_form": source,
                "family_id": self.family_by_form[source],
                "target_count": len(targets),
                "targets": sorted(targets),
            })
        write_csv(diagnostics / "multi_target_form_relations.csv", [
            "source_form", "family_id", "target_count", "targets",
        ], ambiguity_rows)

        summary_rows = [
            {"metric": "families", "value": len(tables["families"])},
            {"metric": "forms", "value": len(tables["forms"])},
            {"metric": "attestations", "value": len(tables["attestations"])},
            {"metric": "readings", "value": len(tables["readings"])},
            {"metric": "senses", "value": len(tables["senses"])},
            {"metric": "etymologies", "value": len(tables["etymologies"])},
            {"metric": "provenances", "value": len(tables["provenances"])},
            {"metric": "family_merge_relations", "value": len(tables["form_relations"])},
            {"metric": "semantic_relations", "value": len(tables["semantic_relations"])},
            {"metric": "unmapped_pages", "value": len(self.unresolved_page_rows)},
            {"metric": "excluded_meta_terms", "value": len(self.excluded_page_rows)},
            {"metric": "unresolved_form_relations", "value": len(self.unresolved_form_relation_rows)},
            {"metric": "multi_target_form_relations", "value": len(ambiguity_rows)},
        ]
        write_csv(diagnostics / "summary.csv", ["metric", "value"], summary_rows)

        manifest = {
            "normalizer_version": VERSION,
            "input_staging": str(self.staging),
            "rules": {
                "fuzzy_form_merging": False,
                "simplified_traditional_conversion": False,
                "semantic_similarity_merging": False,
                "synonym_merging": False,
                "explicit_form_relations_merge": True,
                "explicit_cjkv_descendant_forms_merge": True,
                "explicit_korean_lexeme_bridges_merge": True,
                "hangul_is_reading_not_form": True,
                "poj_is_reading_not_form": True,
            },
            "counts": {row["metric"]: row["value"] for row in summary_rows},
        }
        with (self.output / "manifest.json").open("w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2)
            handle.write("\n")


# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

def unique(values: Iterable[str]) -> List[str]:
    seen: Set[str] = set()
    result = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result



def clean_cjkv_value(value: str) -> str:
    """Clean an explicit written-form value from CJKV/ja-gv without normalizing it."""
    text = (value or "").strip()
    if not text:
        return ""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", r"\1", text)
    text = text.replace("%", "")
    return re.sub(r"\s+", "", text).strip()


def clean_cjkv_reading(value: str) -> str:
    text = (value or "").strip()
    if not text:
        return ""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = text.replace("%", "")
    text = re.sub(r"^\^+", "", text)
    return re.sub(r"\s+", " ", text).strip()


def explicit_hanja_values(value: str) -> List[str]:
    """Parse an explicitly supplied Hanja parameter without inventing forms."""
    raw = (value or "").strip()
    if not raw:
        return []

    # Preserve link targets, discard MediaWiki link markup.
    raw = re.sub(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", r"\1", raw)
    values = []
    for part in raw.split("/"):
        candidate = part.strip()
        if candidate and has_han(candidate):
            values.append(candidate)
    return unique(values)


def explicit_relation_targets(value: str) -> List[str]:
    """Expand source template syntax that explicitly names one or more written forms."""
    raw = (value or "").strip()
    if not raw:
        return []
    raw = re.sub(r"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", r"\1", raw)
    pieces = raw.split("//") if "//" in raw else [raw]
    return unique(piece.strip() for piece in pieces if piece.strip() and has_han(piece.strip()))


def explicit_form_values(value: str, *, split_list: bool) -> List[Tuple[str, str]]:
    """Return explicit written variants from a headword-template value.

    Wiktionary's zh-forms/ja-kanjitab alt syntax commonly uses comma or slash
    separators and a hyphen/colon suffix for a label or reading. We preserve the
    written form and return the suffix separately as evidence; Latin-only
    pronunciation/initialism values are not promoted to Chengyu forms.
    """
    raw_parts = re.split(r"[,/;]", value or "") if split_list else [value or ""]
    result: List[Tuple[str, str]] = []
    seen: Set[str] = set()

    for raw in raw_parts:
        token = raw.strip()
        if not token:
            continue
        qualifier = ""
        if token.startswith("*"):
            token = token[1:].strip()
            qualifier = "marked_nonstandard"

        if ":" in token:
            left, right = token.split(":", 1)
            if has_han(left):
                token = left.strip()
                qualifier = right.strip() or qualifier

        if "-" in token:
            left, right = token.rsplit("-", 1)
            if right.strip():
                token = left.strip()
                qualifier = right.strip() or qualifier

        if not token or not has_han(token) or token in seen:
            continue
        seen.add(token)
        result.append((token, qualifier))
    return result


def qualifier_status(qualifier: str) -> str:
    q = (qualifier or "").strip().lower()
    if not q:
        return "alternative_form"
    if "misspelling" in q or "錯誤拼寫" in qualifier:
        return "misspelling"
    if "misconstruction" in q:
        return "misconstruction"
    if "nonstandard" in q or "非標準" in qualifier or "非標准" in qualifier:
        return "nonstandard"
    if "uncommon" in q:
        return "uncommon_form"
    if "rare" in q:
        return "rare"
    if "slang" in q or "俚語" in qualifier or "網路用語" in qualifier:
        return "slang"
    if "obsolete" in q or "棄用" in qualifier or "古舊" in qualifier:
        return "obsolete"
    return "alternative_form"

def meaningful_plain_text(text: str) -> bool:
    stripped = (text or "").strip()
    if not stripped:
        return False
    # A leftover punctuation mark from a template-only definition is not a sense.
    return bool(re.search(r"[\w\u3400-\u9fff\U00020000-\U000323af]", stripped, re.UNICODE))


def provenance_source_title(category: str) -> str:
    value = category or ""
    match = re.search(r"Chinese chengyu derived from (?:the )?(.+)$", value, re.I)
    if match:
        return match.group(1).strip()
    match = re.search(r"來自《([^》]+)》的漢語成語", value)
    if match:
        return match.group(1).strip()
    return ""


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Normalize staged Wiktionary Chengyu evidence into inspectable families."
    )
    parser.add_argument("staging", type=Path, help="Existing wiktionary_chengyu_staging directory")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output directory (default: <staging>/normalized)",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    staging = args.staging.resolve()
    output = (args.output or (staging / "normalized")).resolve()

    required = ["pages", "definitions", "pronunciations", "relations", "sections", "templates"]
    missing = [name for name in required if not (staging / name).is_dir()]
    if missing:
        print(
            "Missing required staging directories: " + ", ".join(missing),
            file=sys.stderr,
        )
        return 2

    normalizer = ChengyuNormalizer(staging=staging, output=output)
    normalizer.run()
    print(f"[chengyu-normalize] wrote {output}")
    summary = read_csv(output / "diagnostics" / "summary.csv")
    for row in summary:
        print(f"[chengyu-normalize] {row['metric']}={row['value']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
