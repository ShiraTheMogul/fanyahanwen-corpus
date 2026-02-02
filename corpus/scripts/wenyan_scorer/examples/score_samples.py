"""
Example: score a set of files and print a concise table.

Run from repo root after editable install, or by adjusting sys.path to point at this folder.
"""

from pathlib import Path
from wenyan_syntax import score_text

FILES = [
    "檀香山興中會成立宣言__juan_01.txt",
    "中華國民軍政府諭保皇會檄__juan_01.txt",
    "中國同盟會為團結同志宣言__juan_01.txt",
    "設置黨報條例__juan_01.txt",
]

def main():
    for f in FILES:
        p = Path(f)
        if not p.exists():
            continue
        res = score_text(p.read_text(encoding="utf-8"), segment="paragraph", keep_evidence=False)
        s = res["summary"]
        print(f"{f}\tsegments={s['segment_count']}\tmedian={s['median_default_score']:.2f}\tprop_lc={s['proportions']['literary_syntax']:.2f}\tprop_md={s['proportions']['modern_syntax']:.2f}")

if __name__ == "__main__":
    main()
