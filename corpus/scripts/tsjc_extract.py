#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recover the 彙編 / 典 / 部 hierarchy of 欽定古今圖書集成 from the corpus copy.

Each juan file carries its own path in a running title line of the form
  欽定古今圖書集成博物彙編神異典
and lists its 部 in a 目錄 block. Both are read literally; nothing is inferred.
"""
import os, re, csv, glob, json, collections, sys

HOME   = os.path.expanduser('~')
D      = os.path.join(HOME, 'mnt/fanyahanwen-corpus/corpus/中國漢文/raw/清朝/欽定古今圖書集成')
OUT    = os.path.join(HOME, 'leishu')

TITLE  = re.compile(r'欽定古今圖書集成([㐀-鿿]{1,6}彙編)([㐀-鿿]{1,8}典)')
PATH   = re.compile(r'^\s*([㐀-鿿]{1,6}彙編)\s+([㐀-鿿]{1,8}典)\s+第([㐀-鿿\d]+)卷\s*$')
BUMEN  = re.compile(r'^[\s　]*([㐀-鿿]{1,10}部)(彙考|總論|藝文|紀事|雜錄|外編|選句|列傳|部彙考)?[㐀-鿿\d]{0,4}[\s　]*$')

def jnum(p):
    n = re.findall(r'(\d+)', os.path.basename(p))
    return int(n[-1]) if n else 0

def main():
    files = sorted(glob.glob(os.path.join(D, '*juan*.txt')), key=jnum)
    start = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else len(files)
    files = files[start:start+limit]
    rows, seen = [], set()
    stats = collections.Counter()
    # resume: reload anything earlier chunks already found
    part = os.path.join(OUT, 'tsjc_partial.json')
    if start and os.path.exists(part):
        prev = json.load(open(part, encoding='utf-8'))
        rows = prev['rows']; seen = {tuple(k) for k in prev['seen']}
    for f in files:
        try:
            # the 目錄 block sits at the head of each juan; reading the whole
            # 444MB corpus copy is pointless I/O over a mounted volume
            with open(f, encoding='utf-8-sig', errors='replace') as fh:
                t = fh.read(14000)
        except Exception:
            stats['unreadable'] += 1; continue
        head = t[:4000]
        hui = dian = juan = ''
        m = TITLE.search(head)
        if m: hui, dian = m.group(1), m.group(2)
        for line in head.split('\n')[:40]:
            pm = PATH.match(line)
            if pm:
                if not hui: hui, dian = pm.group(1), pm.group(2)
                juan = pm.group(3); break
        if not hui:
            stats['no_path'] += 1
        # 部 labels declared in this juan's 目錄 block
        for line in t.split('\n'):
            bm = BUMEN.match(line)
            if not bm: continue
            bu = bm.group(1)
            if len(bu) < 2: continue
            key = (hui, dian, bu)
            if key in seen: continue
            seen.add(key)
            rows.append({'Raw ID':'', 'Work':'欽定古今圖書集成', 'Region':'中國',
                'Source level':'部', 'Parent':dian, 'Subdivision':bu,
                'Order':len(rows)+1, 'Volume':(f'第{juan}卷' if juan else ''),
                'Exact source label':bu,
                'Source':'Fanya Hanwen corpus (Wikisource transcription)',
                'Notes':f'彙編：{hui}；典：{dian}。部名見本卷目錄。'})
        stats['files'] += 1
    # emit the 彙編 and 典 containers actually attested
    hs = sorted({(r['Notes'].split('；')[0].replace('彙編：',''), r['Parent']) for r in rows})
    top = []
    for hui, dian in hs:
        top.append({'Raw ID':'','Work':'欽定古今圖書集成','Region':'中國','Source level':'典',
            'Parent':hui,'Subdivision':dian,'Order':0,'Volume':'','Exact source label':dian,
            'Source':'Fanya Hanwen corpus (Wikisource transcription)','Notes':'見卷端書名行。'})
    for hui in sorted({h for h,_ in hs}):
        top.insert(0, {'Raw ID':'','Work':'欽定古今圖書集成','Region':'中國','Source level':'彙編',
            'Parent':'','Subdivision':'','Order':0,'Volume':'','Exact source label':hui,
            'Source':'Fanya Hanwen corpus (Wikisource transcription)','Notes':'見卷端書名行。'})
    allrows = top + rows
    json.dump({'rows': rows, 'seen': [list(k) for k in seen]},
              open(os.path.join(OUT,'tsjc_partial.json'),'w',encoding='utf-8'), ensure_ascii=False)
    for i, r in enumerate(allrows, 1): r['Raw ID'] = f'TSJC-{i:05d}'
    cols = ['Raw ID','Work','Region','Source level','Parent','Subdivision','Order','Volume','Exact source label','Source','Notes']
    with open(os.path.join(OUT,'leishu_原目_圖書集成.csv'),'w',encoding='utf-8-sig',newline='') as fh:
        w = csv.DictWriter(fh, fieldnames=cols); w.writeheader(); w.writerows(allrows)
    summary = {'files':stats['files'],'no_path':stats['no_path'],'unreadable':stats['unreadable'],
               'huibian':sorted({h for h,_ in hs}),'dian_count':len({d for _,d in hs}),
               'bu_count':len(rows),'rows':len(allrows)}
    json.dump(summary, open(os.path.join(OUT,'tsjc_summary.json'),'w',encoding='utf-8'), ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
