"""
wenyan_scorer — a construction-based scorer for Literary Chinese.

    from wenyan_scorer import score_text
    result = score_text(open("text.txt", encoding="utf-8-sig").read())
    print(result["summary"]["document_label"])

"""
from .annotation import strip_reading_apparatus
from .calibrate import LogisticModel, featurise, fit
from .rules import DEFAULT_RULESETS, load_rulesets
from .schema import Rule
from .score import score_segment, score_text
from .segment import segment_text

__version__ = "4.0.0"

__all__ = [
    "score_text",
    "score_segment",
    "segment_text",
    "strip_reading_apparatus",
    "load_rulesets",
    "DEFAULT_RULESETS",
    "Rule",
    "LogisticModel",
    "featurise",
    "fit",
    "__version__",
]
