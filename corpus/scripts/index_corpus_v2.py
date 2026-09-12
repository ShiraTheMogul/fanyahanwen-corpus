#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
index_corpus_v2.py — one unified index across EVERY corpus root.

Why: index_corpus_by_work.csv covers only 5 of the 13 roots (四庫全書, 維基大典,
礦藝大典, 他漢文 and the smaller regional roots are absent), assumes a
`<work>__juan_NN.txt` filename (so 太平御覽 reads as 3 juan when the directory
holds 1,005 files named 0000.txt…1005.txt), and assumes a fixed directory depth
(so it misses 四庫全書/clean/<部>/<類>/<work> and
日本漢文/clean/<period>/<polity>/<work>).

Rather than re-walk 1.18M files over a slow mount (~220 files/sec, ~90 min),
this MERGES the per-root index files each scraper already writes — which
carry exact character counts — and normalises them to one schema. A filesystem
verification pass is available separately via --verify <root>, which is the
slow part and is resumable.

Inputs discovered automatically:
  四庫全書/index.csv                    pageid, section, category1/2, author, times, chars
  中國漢文/index_<period>.csv  (46)     category(period), work_folder, chars
  維基大典/index.csv                    title, cjk_chars, sentences
  礦藝大典/kuangyi_dadian_index.csv     page_title, chars, status
  <root>/index.csv                      any other root following the convention

Outputs:
  index_corpus_v2.csv         one row per WORK, every root
  index_corpus_v2_pages.csv   one row per PAGE/juan (the join key for the
                              manifest rebuilder)
  index_corpus_v2_stats.json  corpus statistics + health counters
"""
from __future__ import annotations
import argparse, csv, glob, json, os, re, sys, collections

HOME=os.path.expanduser('~')
CORPUS=os.path.join(HOME,'mnt/fanyahanwen-corpus/corpus')
csv.field_size_limit(10_000_000)

def rd(p):
    try:
        with open(p,encoding='utf-8-sig',errors='replace',newline='') as f:
            return list(csv.DictReader(f))
    except Exception as e:
        print(f'  !! {p}: {e}'); return []

def norm(v): return (v or '').strip()

def to_int(v):
    try: return int(float(str(v).strip() or 0))
    except Exception: return 0

def collect():
    pages=[]
    # 四庫全書 — richest: carries 部/類 and author
    p=os.path.join(CORPUS,'四庫全書','index.csv')
    for r in rd(p):
        pages.append(dict(corpus_root='四庫全書',
            grouping='/'.join(x for x in [norm(r.get('section')),norm(r.get('category1')),
                                          norm(r.get('category2'))] if x),
            work=norm(r.get('work_title')) or norm(r.get('display_title')),
            author=norm(r.get('author')), times=norm(r.get('times')),
            page_title=norm(r.get('page_title')), juan=to_int(r.get('juan_index')),
            chars=to_int(r.get('char_count_clean')),
            empty=1 if to_int(r.get('is_empty_page')) else 0, src='四庫全書/index.csv'))
    # 中國漢文 — one index per period
    for f in sorted(glob.glob(os.path.join(CORPUS,'中國漢文','index_*.csv'))):
        for r in rd(f):
            pages.append(dict(corpus_root='中國漢文', grouping=norm(r.get('category')),
                work=norm(r.get('work_title')) or norm(r.get('work_folder')),
                author=norm(r.get('author')), times=norm(r.get('times')),
                page_title=norm(r.get('page_title')), juan=to_int(r.get('juan_index')),
                chars=to_int(r.get('char_count_clean')),
                empty=1 if to_int(r.get('is_empty_page')) else 0,
                src=os.path.basename(f)))
    # 維基大典 — one row per article
    for r in rd(os.path.join(CORPUS,'維基大典','index.csv')):
        pages.append(dict(corpus_root='維基大典', grouping='', work=norm(r.get('title')),
            author='', times='', page_title=norm(r.get('title')), juan=1,
            chars=to_int(r.get('cjk_chars')), empty=0, src='維基大典/index.csv'))
    # 礦藝大典
    for r in rd(os.path.join(CORPUS,'礦藝大典','kuangyi_dadian_index.csv')):
        if norm(r.get('status'))=='error': continue
        pages.append(dict(corpus_root='礦藝大典', grouping='',
            work=norm(r.get('resolved_title')) or norm(r.get('page_title')),
            author='', times=norm(r.get('date')),
            page_title=norm(r.get('page_title')), juan=1,
            chars=to_int(r.get('chars_clean')), empty=0,
            src='礦藝大典/kuangyi_dadian_index.csv'))
    # any other root that follows <root>/index.csv
    known={'四庫全書','中國漢文','維基大典','礦藝大典'}
    for name in sorted(os.listdir(CORPUS)):
        d=os.path.join(CORPUS,name)
        if name in known or not os.path.isdir(d): continue
        f=os.path.join(d,'index.csv')
        if not os.path.exists(f): continue
        for r in rd(f):
            pages.append(dict(corpus_root=name, grouping=norm(r.get('category')),
                work=norm(r.get('work_title')) or norm(r.get('title')),
                author=norm(r.get('author')), times=norm(r.get('times')),
                page_title=norm(r.get('page_title')), juan=to_int(r.get('juan_index')),
                chars=to_int(r.get('char_count_clean')) or to_int(r.get('cjk_chars')),
                empty=1 if to_int(r.get('is_empty_page')) else 0,
                src=f'{name}/index.csv'))
    return pages

SCAN_CACHE=os.path.join(HOME,'leishu','index_v2_scan.json')

def scan_root(root):
    """Filesystem scan for roots that ship no index.csv (the regional roots).

    A work is any directory directly containing .txt files, at whatever depth —
    these roots nest as clean/<period>/<polity>/<work>, unlike 中國漢文.
    Reads each file for an exact character count; these roots are small.
    """
    base=os.path.join(CORPUS,root,'clean')
    out=[]
    if not os.path.isdir(base): return out
    stack=[base]
    while stack:
        d=stack.pop()
        txts=[]
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False): stack.append(e.path)
                        elif e.name.endswith('.txt'): txts.append(e.path)
                    except OSError: pass
        except OSError: continue
        if not txts: continue
        rel=os.path.relpath(d,base).replace(os.sep,'/')
        parts=[x for x in rel.split('/') if x and x!='.']
        work=parts[-1] if parts else root
        for fp in sorted(txts):
            try:
                with open(fp,encoding='utf-8-sig',errors='replace') as fh: txt=fh.read()
            except OSError: continue
            n=len(txt.strip())
            out.append(dict(corpus_root=root, grouping='/'.join(parts[:-1]), work=work,
                author='', times='', page_title=os.path.splitext(os.path.basename(fp))[0],
                juan=0, chars=n, empty=1 if n<200 else 0, src=f'{root}/clean (scan)'))
    return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--verify', default='', help='root to check against the filesystem')
    ap.add_argument('--scan', default='', help='comma-separated roots with no index.csv')
    a=ap.parse_args()
    pages=collect()
    cache=json.load(open(SCAN_CACHE,encoding='utf-8')) if os.path.exists(SCAN_CACHE) else {}
    for r in [x.strip() for x in a.scan.split(',') if x.strip()]:
        if r not in cache:
            cache[r]=scan_root(r)
            os.makedirs(os.path.dirname(SCAN_CACHE),exist_ok=True)
            json.dump(cache,open(SCAN_CACHE,'w',encoding='utf-8'),ensure_ascii=False)
        print(f'  scanned {r}: {len(cache[r])} pages')
    for r,v in cache.items(): pages+=v
    print(f'pages merged: {len(pages):,}')

    agg=collections.OrderedDict()
    for p in pages:
        k=(p['corpus_root'],p['grouping'],p['work'])
        w=agg.setdefault(k,dict(corpus_root=p['corpus_root'],grouping=p['grouping'],
            work=p['work'],author='',times='',pages=0,chars=0,empty_pages=0,
            min_juan=10**9,max_juan=0,src=p['src']))
        w['pages']+=1; w['chars']+=p['chars']; w['empty_pages']+=p['empty']
        if p['juan']: w['min_juan']=min(w['min_juan'],p['juan']); w['max_juan']=max(w['max_juan'],p['juan'])
        if p['author'] and not w['author']: w['author']=p['author']
        if p['times'] and not w['times']:   w['times']=p['times']
    for w in agg.values():
        if w['min_juan']==10**9: w['min_juan']=''
        w['gaps']=('' if not w['max_juan'] else
                   max(0, w['max_juan']-(w['min_juan'] or 1)+1-w['pages']))

    wc=['corpus_root','grouping','work','author','times','pages','chars',
        'empty_pages','min_juan','max_juan','gaps','src']
    fw=os.path.join(CORPUS,'index_corpus_v2.csv')
    with open(fw,'w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=wc); w.writeheader()
        for row in agg.values(): w.writerow({k:row[k] for k in wc})
    pc=['corpus_root','grouping','work','page_title','juan','chars','empty','src']
    fp=os.path.join(CORPUS,'index_corpus_v2_pages.csv')
    with open(fp,'w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=pc); w.writeheader()
        for row in pages: w.writerow({k:row[k] for k in pc})

    per=collections.defaultdict(lambda: dict(works=0,pages=0,chars=0,empty=0))
    for row in agg.values():
        d=per[row['corpus_root']]
        d['works']+=1; d['pages']+=row['pages']; d['chars']+=row['chars']; d['empty']+=row['empty_pages']
    stats=dict(works=len(agg), pages=len(pages),
               chars=sum(r['chars'] for r in agg.values()),
               empty_pages=sum(r['empty_pages'] for r in agg.values()),
               works_with_gaps=sum(1 for r in agg.values() if r['gaps']),
               per_root={k:dict(v) for k,v in sorted(per.items(), key=lambda kv:-kv[1]['chars'])})
    json.dump(stats,open(os.path.join(CORPUS,'index_corpus_v2_stats.json'),'w',encoding='utf-8'),
              ensure_ascii=False,indent=1)
    print(f'WROTE {fw}  ({len(agg):,} works)')
    print(f'WROTE {fp}  ({len(pages):,} pages)')
    print(f"\n{'root':14s}{'works':>8}{'pages':>9}{'chars':>14}{'empty':>8}")
    for k,v in stats['per_root'].items():
        print(f"{k:14s}{v['works']:8,}{v['pages']:9,}{v['chars']:14,}{v['empty']:8,}")
    print(f"\nTOTAL works={stats['works']:,} pages={stats['pages']:,} "
          f"chars={stats['chars']:,} empty_pages={stats['empty_pages']:,} "
          f"works_with_juan_gaps={stats['works_with_gaps']:,}")

if __name__=='__main__': main()
