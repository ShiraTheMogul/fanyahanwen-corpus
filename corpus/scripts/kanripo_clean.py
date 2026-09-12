#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kanripo_clean.py — turn a Kanripo/mandoku ingestion into corpus-clean text.

What Kanripo leaves in the file, and what this does about it:

1. `#-*- mode: mandoku-view; -*-` Emacs modelines. Pure editor noise, no
   metadata worth keeping (this is the ONLY '#' shape present). Dropped.

2. Hard line breaks at the woodblock column width, mid-sentence:
       周易曰大哉乾元萬物資始乃統天雲行雨施品物流
       形大明終始六位時成時乗六龍以御天乾道變化各
   Rejoined into one paragraph per block. Chinese takes no space at the join.

3. Double-column interlinear notes written as (右/左) pairs:
       見晛曰消(晛/日)(氣/也)   ->   見晛曰消〈晛日氣也〉
   Each bracket contributes right-then-left; consecutive brackets concatenate.
   Verified against the Wikisource witness of the same passage, which reads
   〈晛．日氣也．〉.

4. Indentation in ideographic spaces carries the heading hierarchy. Headings
   keep their own line AND their indent, because that indent is the only
   structural signal these texts have — flattening it would destroy the 原目.

The pre-clean file is preserved under raw/ (this repo's archival side) before
anything is rewritten, so the operation is reversible.
"""
from __future__ import annotations
import argparse, os, re, shutil, sys

IDEO='　'
MODELINE=re.compile(r'^﻿?#-\*-.*-\*-\s*$')
DBL=re.compile(r'[（(]\s*([^（）()/]*?)\s*/\s*([^（）()/]*?)\s*[）)]')

def depth(line):
    n=0
    for ch in line:
        if ch==IDEO: n+=1
        else: break
    return n

def fold_notes(text):
    """(右/左)(右/左) -> 〈右左右左〉, merging runs of adjacent brackets."""
    out=[]; i=0
    while i < len(text):
        m=DBL.match(text,i)
        if not m: out.append(text[i]); i+=1; continue
        parts=[]
        while m:
            parts.append(m.group(1)); parts.append(m.group(2))
            i=m.end(); m=DBL.match(text,i)
        note=''.join(parts).strip()
        if note: out.append('〈'+note+'〉')
    return ''.join(out)

ASCII_RUN=re.compile(r'(?<=[\u3400-\u9fff\uf900-\ufaff])[ ]+(?=[\u3400-\u9fff\uf900-\ufaff])')

def normalise_spaces(text):
    """ASCII space between two Han characters -> ideographic space (U+3000).

    The corpus convention is the ideographic space; the Kanripo 四庫 ingestion
    uses ASCII spaces as its citation separator instead — 910,457 of them across
    51 of the 63 works in 子部/類書類 (御定駢字類編 alone has 345,506). Only runs
    sitting BETWEEN two Han characters are converted, so spaces in Latin text,
    in the title columns and in mixed-script lines are left alone.

    Not applied by default: it touches a lot of text and should be a deliberate
    pass. Enable with --normalise-spaces.
    """
    return ASCII_RUN.sub('\u3000', text)

def clean_text(src, normalise=False):
    lines=src.split('\n')
    out=[]; buf=[]
    def flush():
        if buf:
            out.append(''.join(buf)); buf.clear()
    for ln in lines:
        if MODELINE.match(ln): continue
        ln=ln.replace('﻿','')
        if not ln.strip():
            flush()
            if out and out[-1]!='': out.append('')
            continue
        d=depth(ln)
        if d>0:                      # heading: own line, indent preserved
            flush()
            out.append(fold_notes(ln.rstrip()))
        else:                        # body: keep the woodblock line as-is
            buf.append(fold_notes(ln.strip()))
    flush()
    while out and out[-1]=='': out.pop()
    txt='\n'.join(out)+'\n'
    return normalise_spaces(txt) if normalise else txt

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('root'); ap.add_argument('--archive', default='')
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--normalise-spaces', action='store_true',
                    help='ASCII space between Han characters -> U+3000')
    a=ap.parse_args()
    n=changed=0
    for dirpath,_,files in os.walk(a.root):
        for f in sorted(files):
            if not f.endswith('.txt'): continue
            p=os.path.join(dirpath,f)
            src=open(p,encoding='utf-8-sig',errors='replace').read()
            dst=clean_text(src, a.normalise_spaces)
            n+=1
            if dst==src: continue
            changed+=1
            if a.limit and changed>a.limit: return report(n,changed-1,a.apply)
            if a.apply:
                if a.archive:
                    rel=os.path.relpath(p,a.root)
                    ap_=os.path.join(a.archive,rel)
                    os.makedirs(os.path.dirname(ap_),exist_ok=True)
                    if not os.path.exists(ap_): shutil.copy2(p,ap_)
                with open(p,'w',encoding='utf-8-sig',newline='\n') as fh: fh.write(dst)
    report(n,changed,a.apply)

def report(n,changed,applied):
    print(f'{"applied" if applied else "DRY RUN"}: {changed} of {n} files would change')

if __name__=='__main__': main()
