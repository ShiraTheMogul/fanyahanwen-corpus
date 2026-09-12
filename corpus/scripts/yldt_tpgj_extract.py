#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Recover 原目 rows for 永樂大典 and 太平廣記 from the corpus copies.

永樂大典 is arranged 按韻繫字: each juan header carries its 韻目 (一東, 二支 …),
and under it sit headword entries, each often followed by a short 〈…〉 label.
太平廣記's juan carry entry titles only — its 92 大類 are NOT present in the
transcription, so entries are levelled 條目 and the missing layer is recorded
rather than guessed at.

Both readers track 〈…〉 depth, because the commentary blocks in these texts are
themselves bracketed and would otherwise be mistaken for headings.
"""
import os, re, csv, glob, json

HOME=os.path.expanduser('~')
RAW=os.path.join(HOME,'mnt/fanyahanwen-corpus/corpus/中國漢文/raw')
OUT=os.path.join(HOME,'leishu')
COLS=['Raw ID','Work','Region','Source level','Parent','Subdivision','Order',
      'Volume','Exact source label','Source','Notes']
BAD=set('．。，、：；「」『』（）()〈〉《》【】[]　 ／/…·•←→◄►●○0123456789')
NOISE={'姊妹计划','数据项','永樂大典','返回頁首','終'} - {'終'}   # 終 is a real headword

def jnum(p):
    n=re.findall(r'(\d+)',os.path.basename(p)); return int(n[-1]) if n else 0

def depth_scan(lines):
    """Yield (index, line, depth_before) tracking 〈…〉 nesting across lines."""
    d=0
    for i,l in enumerate(lines):
        before=d
        d+=l.count('〈')-l.count('〉')
        if d<0: d=0
        yield i,l,before

def short_heading(s,maxlen=6):
    if not s or len(s)>maxlen: return False
    if s.startswith('#') or s in NOISE: return False
    if any(c in BAD for c in s): return False
    return bool(re.search(r'[㐀-鿿豈-﫿\U00020000-\U0002ffff]',s))

def do_yongle():
    d=os.path.join(RAW,'明朝/永樂大典')
    files=sorted(glob.glob(os.path.join(d,'*.txt')),key=jnum)
    rows=[]; yun=''; seen=set(); skipped=0
    for f in files:
        if os.path.getsize(f)<400: skipped+=1; continue
        L=open(f,encoding='utf-8-sig',errors='replace').read().split('\n')
        juan=''
        m=None
        for l in L[:40]:
            # Juan number and 韻目 are BOTH Chinese numerals, so they can only be
            # separated by the ideographic space the block print uses. Require it
            # when a 韻目 is present; otherwise take the number alone. Without this,
            # 卷之一萬四千四百六十四　五御 splits in the wrong place.
            t=l.rstrip()
            m=re.match(r'^永樂大典卷之([一二三四五六七八九十百千萬万零〇]+)[\s　]+([一二三四五六七八九十百]{1,3}[㐀-鿿])[\s　]*$',t)
            if m:
                juan=m.group(1); yun=m.group(2); break
            m=re.match(r'^永樂大典卷之([一二三四五六七八九十百千萬万零〇]+)[\s　]*$',t)
            if m:
                juan=m.group(1); break
        if not juan: continue
        if yun and yun not in seen:
            seen.add(yun)
            rows.append(dict(zip(COLS,['','永樂大典','中國','韻目','','',len(seen),f'卷之{juan}',yun,
              'Fanya Hanwen corpus (Wikisource transcription)',
              '《永樂大典》按韻繫字，韻目為檢索結構，非主題分類；不得逕作主題類目使用。'])))
        order=0; started=False
        for i,l,dep in depth_scan(L):
            s=l.strip()
            if re.match(r'^永樂大典卷之',s): started=True; continue
            if not started or dep!=0: continue
            if not short_heading(s): continue
            prev=L[i-1].strip() if i else ''
            if prev!='': continue
            nxt=''
            for k in range(i+1,min(i+4,len(L))):
                if L[k].strip(): nxt=L[k].strip(); break
            label=''
            mm=re.match(r'^〈([^〉]{1,12})〉$',nxt)
            if mm: label=mm.group(1)
            order+=1
            rows.append(dict(zip(COLS,['','永樂大典','中國','字目',yun,s,order,f'卷之{juan}',s,
              'Fanya Hanwen corpus (Wikisource transcription)',
              (f'所繫小目「{label}」。' if label else '')+f'見於卷之{juan}，所屬韻目「{yun}」。'])))
    return rows,skipped

def do_taiping():
    rows=[]
    for sub,tag in [('宋朝/太平廣記','宋朝本'),('北宋/太平廣記','北宋本')]:
        d=os.path.join(RAW,sub)
        files=sorted(glob.glob(os.path.join(d,'*juan*.txt')),key=jnum)
        for f in files:
            if os.path.getsize(f)<400: continue
            txt=open(f,encoding='utf-8-sig',errors='replace').read()
            L=txt.split('\n')
            pt=''
            for l in L[:10]:
                m=re.match(r'^#\s*PAGE_TITLE:\s*(.*)$',l)
                if m: pt=m.group(1).split('/')[-1]
            order=0
            for i,l,dep in depth_scan(L):
                s=l.strip()
                if dep!=0 or not short_heading(s,8): continue
                prev=L[i-1].strip() if i else ''
                if prev!='': continue
                order+=1
                rows.append(dict(zip(COLS,['','太平廣記','中國','條目','',s,order,pt,s,
                  'Fanya Hanwen corpus (Wikisource transcription)',
                  f'{tag}。本層為故事條目，非九十二大類；大類一層不見於本轉寫本，未予補造。'])))
    return rows

yl,skipped=do_yongle()
tp=do_taiping()
allrows=yl+tp
for i,r in enumerate(allrows,1): r['Raw ID']=f'YLTP-{i:05d}'
p=os.path.join(OUT,'index_leishu_原目_永樂大典_太平廣記.csv')
with open(p,'w',encoding='utf-8-sig',newline='') as f:
    w=csv.DictWriter(f,fieldnames=COLS); w.writeheader(); w.writerows(allrows)
import collections
c=collections.Counter((r['Work'],r['Source level']) for r in allrows)
print('WROTE',p,len(allrows),'rows; 永樂大典 empty files skipped:',skipped)
for k,v in sorted(c.items()): print('  ',k[0],k[1],v)
yy=[r['Exact source label'] for r in yl if r['Source level']=='韻目']
print('韻目 recovered:',len(yy)); print('  ','、'.join(yy))
