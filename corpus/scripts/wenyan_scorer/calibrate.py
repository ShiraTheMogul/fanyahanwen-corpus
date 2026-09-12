"""
Calibration: turning asserted weights into fitted ones.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

from .rules import DEFAULT_RULESETS, load_rulesets, run_rule
from .schema import Rule
from .utils import count_han, has_punctuation, per_1000


@dataclass
class LogisticModel:
    """A fitted model. Serialises to plain JSON so it can be read and argued
    with rather than treated as an opaque blob."""

    feature_names: List[str]
    coefficients: List[float]
    intercept: float
    name: str = "unnamed"
    metrics: Dict[str, float] = field(default_factory=dict)
    notes: str = ""

    def predict_one(self, rule_counts: Dict[str, int], han: int) -> float:
        z = self.intercept
        for name, coef in zip(self.feature_names, self.coefficients):
            z += coef * per_1000(rule_counts.get(name, 0), han)
        return _sigmoid(z)

    def to_json(self, path: str) -> None:
        Path(path).write_text(
            json.dumps({
                "name": self.name,
                "feature_names": self.feature_names,
                "coefficients": self.coefficients,
                "intercept": self.intercept,
                "metrics": self.metrics,
                "notes": self.notes,
            }, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    @classmethod
    def from_json(cls, path: str) -> "LogisticModel":
        d = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        return cls(
            feature_names=d["feature_names"],
            coefficients=d["coefficients"],
            intercept=d["intercept"],
            name=d.get("name", Path(path).stem),
            metrics=d.get("metrics", {}),
            notes=d.get("notes", ""),
        )

    def compare_to_hand_weights(self, rules: Sequence[Rule]) -> List[Dict[str, object]]:
        """Where the corpus disagreed with the asserted weights.

        This is the interesting output of a calibration run. A rule whose fitted
        coefficient has the opposite sign to its hand-set weight is a rule whose
        premise the data contradicts — either the pattern is matching something
        other than what its docstring claims, or the belief was wrong.
        """
        by_id = {r.rule_id: r for r in rules}
        rows = []
        for name, coef in zip(self.feature_names, self.coefficients):
            r = by_id.get(name)
            if r is None:
                continue
            asserted = r.weight if r.polarity == "lc" else -r.weight
            rows.append({
                "rule_id": name,
                "polarity": r.polarity,
                "tier": r.tier,
                "asserted_weight": asserted,
                "fitted_coefficient": round(coef, 4),
                "sign_agrees": (asserted > 0) == (coef > 0),
                "cite": r.cite,
            })
        rows.sort(key=lambda d: (d["sign_agrees"], -abs(d["fitted_coefficient"])))
        return rows


def _sigmoid(z: float) -> float:
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)
    return e / (1.0 + e)


def featurise(
    text: str, rules: Sequence[Rule]
) -> Tuple[Dict[str, float], int]:
    """Rule-hit rates per 1000 Han for one text. Punctuation-dependent rules that
    cannot fire are left at zero AND recorded, so an unpunctuated corpus does not
    quietly train the model to believe those constructions are absent."""
    from .annotation import strip_reading_apparatus
    from .utils import strip_markup

    clean = strip_reading_apparatus(strip_markup(text)).text
    han = count_han(clean)
    punctuated = has_punctuation(clean)
    feats: Dict[str, float] = {}
    for r in rules:
        count, _, skipped = run_rule(r, clean, keep_evidence=False, punctuated=punctuated)
        feats[r.rule_id] = 0.0 if skipped else per_1000(count, han)
    return feats, han


def fit(
    texts: Sequence[str],
    labels: Sequence[int],
    *,
    rulesets: Sequence[str] = DEFAULT_RULESETS,
    name: str = "fanyahanwen",
    l2: float = 1.0,
    min_han: int = 60,
    holdout_fraction: float = 0.25,
    seed: int = 20260911,
) -> Tuple[LogisticModel, Dict[str, object]]:
    """Fit a model and report held-out performance.

    `labels`: 1 = Literary Chinese, 0 = not.

    The held-out split is by index with a fixed seed. If your corpus has several
    documents per work, split by WORK before calling this, or the model will be
    scored on paragraphs whose siblings it trained on and the numbers will
    flatter it.
    """
    import random

    rules = load_rulesets(rulesets)
    feature_names = [r.rule_id for r in rules]

    X: List[List[float]] = []
    y: List[int] = []
    for t, lab in zip(texts, labels):
        feats, han = featurise(t, rules)
        if han < min_han:
            continue
        X.append([feats[n] for n in feature_names])
        y.append(int(lab))

    if not X:
        raise ValueError("no samples had enough Han characters to fit on")
    if len(set(y)) < 2:
        raise ValueError(
            f"need both classes to fit; got only label(s) {sorted(set(y))}. "
            "Check the label rule in corpus.py — a corpus of nothing but "
            "Literary Chinese cannot teach a classifier what the alternative "
            "looks like."
        )

    idx = list(range(len(X)))
    random.Random(seed).shuffle(idx)
    cut = int(len(idx) * (1 - holdout_fraction))
    tr, te = idx[:cut], idx[cut:]

    coefs, intercept = _fit_logistic(
        [X[i] for i in tr], [y[i] for i in tr], l2=l2
    )

    model = LogisticModel(
        feature_names=feature_names,
        coefficients=coefs,
        intercept=intercept,
        name=name,
    )
    report = _evaluate(model, [X[i] for i in te], [y[i] for i in te])
    report["train_n"] = len(tr)
    report["test_n"] = len(te)
    report["positive_rate_train"] = round(sum(y[i] for i in tr) / max(1, len(tr)), 4)
    model.metrics = {k: v for k, v in report.items() if isinstance(v, (int, float))}
    return model, report


def _fit_logistic(X, y, *, l2: float):
    try:
        import numpy as np
    except ImportError as exc:  # pragma: no cover
        raise ImportError(
            "calibration needs numpy: pip install numpy"
        ) from exc

    Xa = np.asarray(X, dtype=float)
    ya = np.asarray(y, dtype=float)

    try:
        from sklearn.linear_model import LogisticRegression

        clf = LogisticRegression(
            C=1.0 / max(l2, 1e-9), max_iter=2000, solver="lbfgs"
        )
        clf.fit(Xa, ya)
        return clf.coef_[0].tolist(), float(clf.intercept_[0])
    except ImportError:
        pass

    # Fallback: batch gradient descent with L2. Plain, slow, and sufficient for
    # the feature counts here (order 100 rules).
    n, d = Xa.shape
    w = np.zeros(d)
    b = 0.0
    lr = 0.5
    # Standardise so one high-frequency rule does not dominate the step size.
    mu, sd = Xa.mean(axis=0), Xa.std(axis=0)
    sd[sd == 0] = 1.0
    Xs = (Xa - mu) / sd

    for _ in range(4000):
        z = Xs @ w + b
        p = 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))
        err = p - ya
        gw = (Xs.T @ err) / n + (l2 / n) * w
        gb = err.mean()
        w -= lr * gw
        b -= lr * gb

    # Undo standardisation so coefficients apply to raw rates.
    w_raw = w / sd
    b_raw = b - float((w * mu / sd).sum())
    return w_raw.tolist(), float(b_raw)


def _evaluate(model: LogisticModel, X, y) -> Dict[str, object]:
    if not X:
        return {"note": "empty held-out set"}
    probs = []
    for row in X:
        z = model.intercept + sum(c * v for c, v in zip(model.coefficients, row))
        probs.append(_sigmoid(z))

    best = {"threshold": 0.5, "f1": -1.0}
    for i in range(1, 100):
        th = i / 100.0
        m = _confusion(probs, y, th)
        if m["f1"] > best["f1"]:
            best = {"threshold": th, **m}

    at_half = _confusion(probs, y, 0.5)
    return {
        "auc": round(_auc(probs, y), 4),
        "accuracy_at_0.5": at_half["accuracy"],
        "precision_at_0.5": at_half["precision"],
        "recall_at_0.5": at_half["recall"],
        "f1_at_0.5": at_half["f1"],
        "best_threshold": best["threshold"],
        "f1_at_best": best["f1"],
        "precision_at_best": best["precision"],
        "recall_at_best": best["recall"],
    }


def _confusion(probs, y, threshold) -> Dict[str, float]:
    tp = sum(1 for p, t in zip(probs, y) if p >= threshold and t == 1)
    fp = sum(1 for p, t in zip(probs, y) if p >= threshold and t == 0)
    fn = sum(1 for p, t in zip(probs, y) if p < threshold and t == 1)
    tn = sum(1 for p, t in zip(probs, y) if p < threshold and t == 0)
    prec = tp / (tp + fp) if tp + fp else 0.0
    rec = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    acc = (tp + tn) / max(1, len(y))
    return {
        "accuracy": round(acc, 4), "precision": round(prec, 4),
        "recall": round(rec, 4), "f1": round(f1, 4),
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
    }


def _auc(probs, y) -> float:
    pos = [p for p, t in zip(probs, y) if t == 1]
    neg = [p for p, t in zip(probs, y) if t == 0]
    if not pos or not neg:
        return float("nan")
    pairs = 0
    wins = 0.0
    for p in pos:
        for q in neg:
            pairs += 1
            if p > q:
                wins += 1
            elif p == q:
                wins += 0.5
    return wins / pairs if pairs else float("nan")
