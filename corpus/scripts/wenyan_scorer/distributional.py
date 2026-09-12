"""
Distributional profiles (no semantic classifier compatibility needed).

We measure:
- NUM+N (no middle slot), deconfounded for common measure/time nouns
- NUM+X+N (potential classifier slot)
- N+NUM and N+X+NUM (post-nominal counting patterns)
- 個/个 density in NUM-CLF-N frames (modern general classifier strategy)
- pronoun distribution approximations
"""
from __future__ import annotations
import re
from typing import Dict

_HAN = r"[\u4e00-\u9fff]"
_NUM = r"[一二三四五六七八九十百千〇零兩两]"

_BARE_MEASURE_NOUNS = "年月日天時分秒里尺丈斤兩两斗升石錢钱文貫贯人名位口戶户"

_EXCLUDE_X = "一二三四五六七八九十百千〇零兩两的之者所也矣乎哉耶耳焉於于與与而則则乃故其吾我余予汝爾女他她它們们嗎吗呢吧啊呀嘛"
_X = rf"[^{{{_EXCLUDE_X}{_NUM}}}]"

_RE_NUM_N = re.compile(rf"({_NUM})({_HAN})")
_RE_NUM_X_N = re.compile(rf"({_NUM})({_X})({_HAN})")
_RE_N_NUM = re.compile(rf"({_HAN})({_NUM})")
_RE_N_X_NUM = re.compile(rf"({_HAN})({_X})({_NUM})")

_RE_GE_FRAME = re.compile(rf"({_NUM})(個|个)({_HAN})")
_RE_MEI_FRAME = re.compile(rf"({_NUM})枚({_HAN})")

def _count(pat: re.Pattern, text: str) -> int:
    return sum(1 for _ in pat.finditer(text))

def classifier_profile(text: str) -> Dict[str, int]:
    num_n = _count(_RE_NUM_N, text)
    num_x_n = _count(_RE_NUM_X_N, text)
    n_num = _count(_RE_N_NUM, text)
    n_x_num = _count(_RE_N_X_NUM, text)
    ge_frame = _count(_RE_GE_FRAME, text)
    mei_frame = _count(_RE_MEI_FRAME, text)

    confounds = sum(1 for _ in re.finditer(rf"({_NUM})([{_BARE_MEASURE_NOUNS}])", text))
    num_n_deconf = max(0, num_n - confounds)

    yi_n = _count(re.compile(rf"(一)({_HAN})"), text)
    yi_x_n = _count(re.compile(rf"(一)({_X})({_HAN})"), text)

    ge2_n = _count(re.compile(rf"([二三四五六七八九十百千兩两])({_HAN})"), text)
    ge2_x_n = _count(re.compile(rf"([二三四五六七八九十百千兩两])({_X})({_HAN})"), text)
    ge2_conf = sum(1 for _ in re.finditer(rf"([二三四五六七八九十百千兩两])([{_BARE_MEASURE_NOUNS}])", text))
    ge2_n_deconf = max(0, ge2_n - ge2_conf)

    return {
        "clf_num_n_raw": num_n,
        "clf_num_n_deconf": num_n_deconf,
        "clf_num_x_n": num_x_n,
        "clf_n_num": n_num,
        "clf_n_x_num": n_x_num,
        "clf_ge_frame": ge_frame,
        "clf_mei_frame": mei_frame,
        "clf_yi_n": yi_n,
        "clf_yi_x_n": yi_x_n,
        "clf_ge2_n_deconf": ge2_n_deconf,
        "clf_ge2_x_n": ge2_x_n,
    }

_RE_WO_SUBJ_START = re.compile(r"(?:^|[。！？；\n\r])\s*我(?=(是|很|要|想|喜歡|喜欢|對|在|有|覺得|觉得))")
_RE_WO_OBJ_AFTER_VERB = re.compile(rf"{_HAN}(我)(?=[，。！？；\s]|$)")
_RE_LC_1P_ALT = re.compile(r"(吾|余|予)(?=" + _HAN + ")")
_RE_LC_2P = re.compile(r"(汝|爾|女)(?=" + _HAN + ")")
_RE_MD_2P = re.compile(r"(你|您)(?=" + _HAN + ")")

def pronoun_profile(text: str) -> Dict[str, int]:
    return {
        "pro_wo_subj_start": _count(_RE_WO_SUBJ_START, text),
        "pro_wo_obj_after_verb": _count(_RE_WO_OBJ_AFTER_VERB, text),
        "pro_lc_1p_alt": _count(_RE_LC_1P_ALT, text),
        "pro_lc_2p": _count(_RE_LC_2P, text),
        "pro_md_2p": _count(_RE_MD_2P, text),
    }
