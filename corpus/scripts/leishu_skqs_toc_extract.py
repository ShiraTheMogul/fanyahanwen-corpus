#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
leishu_skqs_toc_extract.py — recover leaf-level 原目 from 四庫全書/clean/子部/類書類.

Reads the CLEAN side only. raw/ is deprecated in this repo (archival copies of
old scrapes) and must not be used as a source of truth.

The clean texts are the Kanripo/mandoku ingestion, whose structure is explicit:
INDENT DEPTH IN IDEOGRAPHIC SPACES IS THE HIERARCHY LEVEL.

    欽定四庫全書                     depth 0  — running head
    　藝文類聚卷二　　　唐 歐陽詢 撰   depth 1  — volume title line
    　天部下(雪/電)(雨/霧)            depth 1  — 部
    　　雪                           depth 2  — 子目
    毛詩曰北風其涼雨雪其雱…            depth 0  — body, wrapped to the block width

So a heading is an indented short line; its depth gives its level. Body text is
unindented and wraps mid-sentence at the woodblock line width.

Kanripo writes double-column interlinear notes as (上/下). Those are captured
into the Notes column, never left inside the category name.

Nothing is inferred from wording. Container vs leaf comes from relative indent
depth within the work, not from a terminal 部/類/門 — suffix guessing promotes
百部 (the plant Stemona), 蒲類 (a polity) and 玉篇 (a book) to category status.
"""
from __future__ import annotations
import csv, json, os, re, sys, collections

HOME=os.path.expanduser('~')
CORPUS=os.path.join(HOME,'mnt/fanyahanwen-corpus/corpus')
BASE=os.path.join(CORPUS,'四庫全書/clean/子部/類書類')
OUT=os.path.join(HOME,'leishu')
COLS=['Raw ID','Work','Region','Source level','Parent','Subdivision','Order',
      'Volume','Exact source label','Source','Notes']

IDEO='　'
CITE=re.compile(r'[曰云]')
NOTE=re.compile(r'[（(]([^（）()]*)[）)]')
BAD=set('。，、：；「」『』〈〉《》【】[]!？?…·•←→◄►●○※◆')
SKIP=re.compile(r'^(欽定四庫全書|#|臣等謹案|總校官|校對官|提要)')
TITLELINE=re.compile(r'[卷巻][一二三四五六七八九十百]+')

def depth(line):
    n=0
    for ch in line:
        if ch==IDEO: n+=1
        else: break
    return n

def jkey(p):
    n=re.findall(r'(\d+)',os.path.basename(p))
    return (int(n[-1]) if n else 0,p)

def heads(path, work, maxlen=12):
    """Yield (depth, label, note) for every indented heading line."""
    out=[]
    with open(path,encoding='utf-8-sig',errors='replace') as f:
        for raw in f:
            line=raw.rstrip('\n')
            d=depth(line)
            if d==0: continue                     # body text
            s=line.strip()
            if not s or SKIP.match(s): continue
            if CITE.search(s): continue           # a quotation, not a heading
            notes=[m.strip() for m in NOTE.findall(s)]
            s=NOTE.sub('',s).strip()
            s=s.replace(IDEO,'').strip()
            if not s or len(s)>maxlen: continue
            if s.startswith(work) or TITLELINE.search(s): continue
            if any(c in BAD for c in s): continue
            if not re.search(r'[㐀-鿿豈-﫿\U00020000-\U0002ffff]',s): continue
            out.append((d,s,'；'.join(n for n in notes if n)))
    return out

LEVELNAME={1:'部類',2:'子目',3:'子目',4:'細目',5:'細目'}

def main():
    only=set(a for a in sys.argv[1:] if not a.startswith('-'))
    works=sorted(w for w in os.listdir(BASE) if os.path.isdir(os.path.join(BASE,w)))
    if only: works=[w for w in works if w in only]
    rows=[]; report=[]
    for work in works:
        d=os.path.join(BASE,work)
        files=sorted((os.path.join(d,f) for f in os.listdir(d) if f.endswith('.txt')),key=jkey)
        # the work's own minimum heading depth is its container level
        alld=[h[0] for fp in files for h in heads(fp,work)]
        if not alld:
            report.append(dict(work=work,files=len(files),containers=0,leaves=0,depths={})); continue
        base_d=min(alld)
        hist=collections.Counter(alld)
        stack={}; n_c=n_l=0
        for fp in files:
            vol=os.path.splitext(os.path.basename(fp))[0].split('__')[-1]
            order=0
            for dep,lab,note in heads(fp,work):
                rel=dep-base_d+1
                stack[rel]=lab
                for k in list(stack):
                    if k>rel: del stack[k]
                parent=stack.get(rel-1,'')
                lvl=LEVELNAME.get(rel,'細目')
                if rel==1: n_c+=1; order=0
                else: n_l+=1; order+=1
                n=f'Kanripo/mandoku 清本，縮排層級 {dep}（相對層 {rel}）。'
                if note: n+=f'原文夾註：{note}。'
                if parent: n+=f'上層標目「{parent}」。'
                rows.append(dict(zip(COLS,['',work,'中國',lvl,parent,
                    ('' if rel==1 else lab),order if rel>1 else n_c,vol,lab,
                    f'corpus 四庫全書/clean/子部/類書類/{work}',n])))
        report.append(dict(work=work,files=len(files),containers=n_c,leaves=n_l,
                           depths=dict(sorted(hist.items()))))
    for i,r in enumerate(rows,1): r['Raw ID']=f'SKQS-{i:06d}'
    os.makedirs(OUT,exist_ok=True)
    p=os.path.join(OUT,'index_leishu_原目_四庫全書類書類.csv')
    with open(p,'w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=COLS); w.writeheader(); w.writerows(rows)
    json.dump(report,open(os.path.join(OUT,'skqs_coverage.json'),'w',encoding='utf-8'),
              ensure_ascii=False,indent=1)
    print(f'WROTE {p}  rows={len(rows)}')
    print(f"{'work':22s}{'files':>6}{'cont':>6}{'leaf':>8}  depths")
    for r in sorted(report,key=lambda x:-x['leaves'])[:16]:
        print(f"{r['work']:22s}{r['files']:6d}{r['containers']:6d}{r['leaves']:8d}  {r['depths']}")

if __name__=='__main__': main()
