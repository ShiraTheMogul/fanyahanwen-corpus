#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
leishu_attestation.py — record what each 類書 excerpts, as POINTERS.

A 類書 is a compilation: its bulk is other works quoted verbatim. Holding it as
plain text inflates corpus statistics (the same 史記 passage is counted once in
史記 and again inside 藝文類聚, 太平御覽, 淵鑑類函 …). Recording the citation as an
attestation instead gives the compilation relation without duplicating anything.

Method. In these texts a citation opens with the cited work's title immediately
followed by 曰 or 云 — 「淮南子曰…」, 「山海經云…」. The head is taken only at a
real boundary (line start, or after 。，、；：？！ or a closing bracket), so that
preceding prose does not bleed into the title (「…之荆州記」). Interlinear notes
in （…） are stripped first. A leading 又 (「又曰」, continuing the previous
citation) is not a new head.

Resolution against the corpus uses index_corpus_v2.csv, plus:
  * graph-variant folding (荘→莊, 説→說, 畧→略 …), since the 四庫 and Wikisource
    witnesses differ in these;
  * an alias table for the classics cited under short names (毛詩→詩經,
    左傳→春秋左氏傳, 周官→周禮, 魏志→三國志 …).

Roughly a third of citations resolve. Most of the rest are genuinely lost works
— 讖緯 apocrypha such as 春秋元命苞, 尚書中候, 孝經援神契 — so the unresolved
tally is a useful "cited but not held" inventory, not a failure. It is written
out alongside the resolved attestations.

Output (UTF-8 with BOM):
  corpus/index_leishu_徵引.csv        leishu × cited work × count, resolved flag
  corpus/index_leishu_徵引_未詳.csv    unresolved heads, for alias/acquisition work
State is per-leishu and resumable.
"""
from __future__ import annotations
import argparse, collections, csv, glob, json, os, re, sys

HOME=os.path.expanduser('~')
CORPUS=os.path.join(HOME,'mnt/fanyahanwen-corpus/corpus')
LEISHU=os.path.join(CORPUS,'四庫全書/clean/子部/類書類')
STATE=os.path.join(HOME,'leishu','attest_state.json')

VAR=str.maketrans('荘説畧尓応躰虫閒䇿逺','莊說略爾應體蟲間策遠')
def canon(s): return s.translate(VAR)

# Standard histories and classics cited under short or older names. Where a short
# name is genuinely ambiguous (唐書 = 舊唐書 in Song leishu, 新唐書 after 1060) the
# mapping is recorded as such so it stays auditable rather than silently chosen.
HISTORY={'唐書':'舊唐書','後魏書':'魏書','齊書':'南齊書','後周書':'周書','後齊書':'北齊書',
 '大戴禮':'大戴禮記','孫卿子':'荀子','漢志':'漢書','前漢書':'漢書','范曄後漢書':'後漢書',
 '沈約宋書':'宋書','蕭子顯齊書':'南齊書','臧榮緒晉書':'晉書','王隠晉書':'晉書',
 '謝承後漢書':'後漢書','華嶠後漢書':'後漢書','司馬彪續漢書':'續漢書','袁山松後漢書':'後漢書'}
# not citations at all: commentator names and textual-variant markers
# 孔子曰 is reported speech; the book is 論語. 老子/莊子/孟子/荀子 are genuine book
# titles in this idiom and are NOT blocked.
NOISE={'孔子','夫子','子曰','孔子家語曰','師古','郭璞注','一本','注','按','又按','疏','箋','傳','鄭玄','顔師古','善注',
 '李善注','或作','一作','今按','舊注','集解','正義','索隱','音義','釋文'}
ALIAS={'毛詩':'詩經','詩':'詩經','左傳':'春秋左氏傳','左氏傳':'春秋左氏傳',
 '春秋左傳':'春秋左氏傳','周官':'周禮','禮':'禮記','易':'周易','書':'尚書',
 '說文':'說文解字','風俗通':'風俗通義','魏志':'三國志','蜀志':'三國志','吳志':'三國志',
 '呉志':'三國志','穀梁傳':'春秋穀梁傳','公羊傳':'春秋公羊傳','韓子':'韓非子',
 '世說':'世說新語','東觀記':'東觀漢記','漢官儀':'漢官儀','續漢書':'續漢書'}
# author-prefixed citation forms: 謝承後漢書 -> 後漢書, 王隠晉書 -> 晉書
AUTHPRE=re.compile(r'^[㐀-鿿]{1,2}(?=(後漢書|晉書|漢書|史記|春秋|國志)$)')
# 原 / 增 mark provenance in 御定淵鑑𩔖函 and its family (原 = inherited from 唐類函,
# 增 = added under Kangxi). They sit flush against the cited title with no separator:
# 「原釋名曰…」「增説文云…」, so they must be stripped like a leading 又.
HAN='\u3400-\u9fff\uf900-\ufaff\U00020000-\U0002ffff'
# Separators in these texts are ASCII spaces, not ideographic ones — 204 of the 216
# citations in 淵鑑類函 卷五 are space-separated. Omitting ' ' from the boundary class
# found 5 heads in a juan that actually holds ~200.
BOUND='。，、；：？！ \t\u3000\n〉》'
CIT=re.compile('(?:^|['+BOUND+'])(?:[又原增増]{1,3})?(['+HAN+']{2,8}?)(?:曰|云)')
NOTE=re.compile(r'[（(][^（）()]*[）)]')

# --- category context -------------------------------------------------------
# Kanripo/SKQS transcriptions carry the 原目 hierarchy as leading ideographic
# spaces: one per level. A citation therefore sits under whatever headings are
# open above it, and that path is what lets a leishu's own taxonomy be pushed
# onto the works it quotes.
IDEO='\u3000'

def _depth(line):
    n=0
    for ch in line:
        if ch==IDEO: n+=1
        else: break
    return n

def heading_of(line):
    """Return the heading text of an indented line, or None.

    Brackets must be stripped BEFORE the length test: 「　天部下(雪/電)　(雨/霧)」
    is a 部 heading but runs to 20 characters with its interlinear note attached,
    so a naive length check drops it and every citation beneath it loses its 部.
    """
    if _depth(line)==0: return None
    t=NOTE.sub('',line).replace(IDEO,'').strip()
    if not t or len(t)>10: return None
    if re.search('[曰云]',t): return None                     # a citation, not a heading
    if re.search(r'[卷巻][一二三四五六七八九十百]',t): return None  # juan rubric
    if any(c in '。，、；：？！' for c in t): return None        # running prose
    if not re.search('['+HAN+']',t): return None
    return t

# Graph variants that separate a folder name or a heading from the way the same
# label is written in the 原目 index: 𩔖/類 (the Wikisource page title), 巻/卷,
# 増/增, 諌/諫. canon() already covers the body-text set.
LVAR=str.maketrans({'𩔖':'類','巻':'卷','増':'增','諌':'諫','冊':'冊'})
def lkey(s): return canon(s).translate(LVAR)

NUMTAIL=re.compile(r'(?:第)?[一二三四五六七八九十百千]+$')

def _adepth(line):
    """Level for an SKQS flat transcription, where two ASCII spaces mark the body.

    These files invert the usual convention: the 部 rubric and the prose sit at two
    spaces, while the 子目 heading is flush left (山堂肆考 「醫士」, 古今事文類聚
    「燧人教漁」). Treating the indented line as the SHALLOWER level therefore keeps
    部 above 子目 rather than upside down.
    """
    return 0 if line[:2]=='  ' else 1

def load_genmoku():
    """{work: {label: canonical path}} from the extracted 原目 indexes.

    Not every leishu transcription marks its hierarchy with indentation. 御定淵鑑
    𩔖函, 冊府元龜 and 古今事文類聚 come through the SKQS pipeline with two ASCII
    spaces and no depth at all, so the indent stack finds nothing in them — and
    淵鑑類函 alone carries 18,658 of the corpus's 69,926 attested citations. For
    those, the work's own 原目 (already extracted, with its Parent chain) is the
    closed vocabulary: a line is a heading when the 原目 says that label exists,
    and the path comes from the tree rather than from the page layout.
    """
    par=collections.defaultdict(dict)
    for p in glob.glob(os.path.join(CORPUS,'index_leishu_原目*.csv')):
        try: rows=list(csv.DictReader(open(p,encoding='utf-8-sig')))
        except OSError: continue
        for r in rows:
            w=lkey((r.get('Work') or '').strip())
            lab=lkey((r.get('Exact source label') or r.get('Subdivision') or '').strip())
            if not w or not lab: continue
            par[w].setdefault(lab, lkey((r.get('Parent') or '').strip()))
    voc={}
    for w,pm in par.items():
        d={}
        for lab in pm:
            chain=[]; cur=lab; seen=set()
            while cur and cur not in seen and len(chain)<6:
                seen.add(cur); chain.append(cur); cur=pm.get(cur,'')
            d[lab]=' > '.join(reversed(chain))
        voc[w]=d
    return voc

def vocab_heading(text, voc_w):
    """Canonical path for a line that names a 原目 label, else None."""
    t=lkey(text)
    if t in voc_w: return voc_w[t]
    t2=NUMTAIL.sub('', t)                      # 人部五十二 -> 人部, 直諫第五 -> 直諫
    if t2 and t2!=t and t2 in voc_w: return voc_w[t2]
    if len(t)>1 and t[-1] in '上中下' and t[:-1] in voc_w: return voc_w[t[:-1]]
    return None

# A 類目 is a noun phrase. A heading that ends in a sentence-final particle, or
# opens with a connective, is a fragment of prose that the indent rule mistook for
# a heading — 事物紀原 produced 「始也」 and 「當為此乎」 this way. Real categories DO
# contain these graphs (大夫, 若木, 則天皇后, 故舊部), so the filter never overrides
# the work's own 原目: it only judges labels the 原目 cannot confirm.
PTAIL=set('也矣乎哉焉歟耶邪')
PHEAD=set('而則故亦乃雖曰')

def plausible_label(lab, vw):
    if vw and vocab_heading(lab, vw): return True
    return not (lab[-1] in PTAIL or lab[0] in PHEAD)


def bare_label(line):
    """The line stripped to a bare short label, or None if it is not one."""
    t=NOTE.sub('',line).replace(IDEO,'').replace(' ','').strip()
    if not t or len(t)>10: return None
    if re.search('[曰云]',t): return None
    if any(c in '。，、；：？！〈〉《》「」〔〕' for c in t): return None
    if not re.search('['+HAN+']',t): return None
    return t

# Modern wiki roots cannot be cited by a pre-modern 類書. Leaving them in the
# title index made 「孔子曰」 (speech) resolve to a 1-page 維基大典 article, and
# 「後漢」 likewise — 1,280 and 1,244 spurious citations respectively.
MODERN_ROOTS={'維基大典','礦藝大典'}

# Canonical works that are always valid citation targets, whether or not the
# corpus happens to hold a substantive copy. Without this the substance guard
# below drops 爾雅 (the corpus holds it as 爾雅註疏) and similar, losing a
# heavily-cited classic. Whether the corpus HOLDS the work is recorded
# separately in the `match` column as *-unheld.
CLASSICS={'爾雅','周易','尚書','詩經','禮記','周禮','儀禮','春秋','論語','孝經',
 '春秋左氏傳','春秋公羊傳','春秋穀梁傳','老子','莊子','孟子','荀子','管子','墨子',
 '韓非子','列子','文子','淮南子','呂氏春秋','山海經','楚辭','說文解字','釋名',
 '方言','廣雅','史記','漢書','後漢書','三國志','晉書','宋書','南齊書','梁書','陳書',
 '魏書','北齊書','周書','隋書','舊唐書','新唐書','南史','北史','國語','戰國策',
 '東觀漢記','風俗通義','博物志','搜神記','世說新語','抱朴子','論衡','白虎通',
 '穆天子傳','水經注','齊民要術','神農本草經','黃帝內經','孔子家語','大戴禮記'}

MIN_CHARS=500   # a work the corpus holds as a few-hundred-character stub is not
                # what a 類書 is quoting; attributing citations to it is worse than
                # leaving them unresolved (this is what made 孔子 look 600×-cited).

def load_titles():
    t={}; size=collections.Counter()
    p=os.path.join(CORPUS,'index_corpus_v2.csv')
    for r in csv.DictReader(open(p,encoding='utf-8-sig')):
        if r['corpus_root'] in MODERN_ROOTS: continue
        s=re.sub(r'\s*[（(][^）)]*[）)]\s*$','',r['work']).strip()
        if not (1<len(s)<=12): continue
        size[canon(s)]+=int(r['chars'] or 0)
    for r in csv.DictReader(open(p,encoding='utf-8-sig')):
        if r['corpus_root'] in MODERN_ROOTS: continue
        s=re.sub(r'\s*[（(][^）)]*[）)]\s*$','',r['work']).strip()
        if 1<len(s)<=12 and size[canon(s)]>=MIN_CHARS: t.setdefault(canon(s), s)
    return t

def resolve(head, titles):
    h=canon(head)
    if h and not h.strip('又原增増'): return None, 'noise'
    if h in NOISE: return None, 'noise'
    if h in CLASSICS:
        return (titles.get(h, h), 'exact' if h in titles else 'classic-unheld')
    # a head made only of provenance markers (增又, 又, 原又) is the tail of a
    # 「增又曰」 continuation, not a title
    if h and not h.strip('又原增増'): return None, 'noise'
    if h in NOISE: return None, 'noise'
    if h in titles: return titles[h], 'exact'
    g=HISTORY.get(h)
    if g:
        return (titles.get(canon(g), g),
                'history-alias' + ('' if canon(g) in titles else '-unheld'))
    a=ALIAS.get(h)
    if a:
        return titles.get(canon(a), a), ('alias' if canon(a) in titles else 'alias-unheld')
    s=AUTHPRE.sub('',h)
    if s!=h and s in titles: return titles[s], 'author-stripped'
    # General author/compiler prefix: 杜氏通典, 崔豹古今注, 王子年拾遺記, 桓譚新論,
    # 應劭漢官儀. Suffix-match only — prefix-matching would wrongly fold the lost
    # 三國典略 into 三國.
    for k in (1,2,3):
        tail=h[k:]
        if len(tail)>=2 and tail not in NOISE and tail in titles:
            return titles[tail], 'author-prefix-stripped'
    # a stray 増/增 that the regex prefix group missed
    st=h.lstrip('又原增増')
    if len(st)>=2 and st not in NOISE and st in titles: return titles[st], 'marker-stripped'
    return None, ''

DBL=re.compile(r'[（(]\s*([^（）()/]{1,8})\s*/\s*([^（）()/]{0,8})\s*[）)]')

def bracket_line(line, titles):
    """The 錦繡萬花谷 idiom on one raw line — brackets still intact.

    This has to see the ORIGINAL line: scan() rewrites （…） to 。…。 so that heads
    inside interlinear notes stay findable, and that substitution also destroys
    the very brackets this idiom depends on. Passing it the substituted text
    silently produced zero bracket citations for the whole corpus.
    """
    out=collections.Counter()
    for m in DBL.finditer(line):
        cand=canon((m.group(1)+m.group(2)).strip())
        if cand in NOISE: continue
        if 2<=len(cand)<=10 and cand in titles: out[titles[cand]]+=1
    return out

def lineinitial_line(line, titles, known):
    """The 駢志 idiom on one line: source title first, no 曰/云."""
    if line[:1] not in (' ','\u3000','\t'): return None
    t=line.strip()
    for n in range(8,1,-1):
        if len(t)<n: continue
        c=canon(t[:n])
        if c in NOISE: continue
        if c in known and c in titles: return titles[c]
    return None

def scan(work, titles, known=None, voc=None):
    d=os.path.join(LEISHU, work)
    if not os.path.isdir(d): return None
    known=known or set()
    hits=collections.Counter(); miss=collections.Counter(); how={}
    bycat=collections.Counter()
    files=[f for f in os.listdir(d) if f.endswith('.txt')]
    for f in files:
        try: t=open(os.path.join(d,f),encoding='utf-8-sig',errors='replace').read()
        except OSError: continue
        # Do NOT delete interlinear notes: in 事類賦, 古儷府, 北堂書鈔 and 小學紺珠
        # the citations live INSIDE the （…） notes. Replace the brackets with a
        # boundary character so heads are still found but cannot run together.
        # The replacement keeps the note's own characters, newlines included, so
        # the substituted text has exactly the same line count as the original —
        # which is what lets the indent-derived heading stack be read off the
        # untouched lines while the citations are read off the substituted ones.
        sub=NOTE.sub(lambda m:'。'+m.group(0)[1:-1]+'。', t)
        olines=t.split('\n'); slines=sub.split('\n')
        if len(olines)!=len(slines):        # defensive; should not happen
            olines=slines
        # Which structural signal this file carries. Fewer than five ideographic
        # indents means the transcription is flat (SKQS two-space style), so the
        # 原目 vocabulary is the only way in.
        use_indent = sum(1 for l in olines if l[:1]==IDEO) >= 5
        vindent = (voc or {}).get(lkey(work))      # consulted, not required
        vw = None if use_indent else vindent
        # Third case: flat transcription with no 原目 extracted yet (山堂肆考,
        # 古今事文類聚, 花木鳥獸集𩔖). Fall back to the page's own shape — a short,
        # citation-free line is the heading — with the particle filter as the only
        # guard, since there is no vocabulary to check against.
        use_ascii = not use_indent and not vw
        stack={}; vpath=''
        for oline,sline in zip(olines,slines):
            # Decide content-vs-heading from the citations the line actually
            # yields, across ALL three idioms. Testing only the 曰/云 idiom let a
            # heading swallow the line-initial citations sitting on the same line
            # (讀書紀數畧 lost 44 of its 58 that way), and testing none at all let
            # 御定分類字錦's note-packed entry words swallow 2,310.
            cits=list(CIT.finditer(sline))
            brk=bracket_line(oline, titles)
            li=lineinitial_line(oline, titles, known)
            if not cits and not brk and not li:
                if use_indent:
                    h=heading_of(oline)
                    if h is not None and plausible_label(h, vindent):
                        dp=_depth(oline)
                        for k in [k for k in stack if k>=dp]: del stack[k]
                        stack[dp]=h
                        continue
                elif vw:
                    lab=bare_label(oline)
                    if lab:
                        p=vocab_heading(lab, vw)
                        if p: vpath=p; continue
                elif use_ascii:
                    lab=bare_label(oline)
                    if lab and plausible_label(lab, None) and not lab.startswith(work):
                        dp=_adepth(oline)
                        for k in [k for k in stack if k>=dp]: del stack[k]
                        stack[dp]=lab
                        continue
                continue                    # blank or unclassifiable: nothing to record
            path=(' > '.join(stack[k] for k in sorted(stack))
                  if use_indent or use_ascii else vpath)
            for m in cits:
                r,mode=resolve(m.group(1), titles)
                if r==work: continue
                if r:
                    hits[r]+=1; how.setdefault(r,mode)
                    if path: bycat[(path,r)]+=1
                elif mode!='noise': miss[canon(m.group(1))]+=1
            for k,v in brk.items():
                if k==work: continue                # a leishu does not cite itself
                hits[k]+=v; how.setdefault(k,'bracket-note')
                if path: bycat[(path,k)]+=v
            if li and li!=work:                     # running title, not a citation
                hits[li]+=1; how.setdefault(li,'line-initial')
                if path: bycat[(path,li)]+=1
    return dict(work=work, files=len(files), hits=dict(hits), miss=dict(miss),
                how=how, bycat={k[0]+'\t'+k[1]:v for k,v in bycat.items()})

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--works', default=''); ap.add_argument('--budget', type=int, default=140)
    a=ap.parse_args()
    titles=load_titles()
    VOC=load_genmoku()
    print(f'原目 vocabulary: {len(VOC)} works, {sum(len(v) for v in VOC.values()):,} labels')
    # books the 曰/云 pass has already seen cited >=3 times: the precision guard
    # for the line-initial rule
    # Sourced from the published attestation CSV rather than the state file, so a
    # full re-scan (state cleared) still has the guard available.
    KNOWN=set(); _agg=collections.Counter()
    _csv=os.path.join(CORPUS,'index_leishu_徵引.csv')
    if os.path.exists(_csv):
        for _r in csv.DictReader(open(_csv,encoding='utf-8-sig')):
            _agg[canon(_r['cited_work'])]+=int(_r['citations'])
    if os.path.exists(STATE):
        for _r in json.load(open(STATE,encoding='utf-8')).values():
            for _k,_n in _r['hits'].items(): _agg[canon(_k)]+=_n
    KNOWN={k for k,n in _agg.items() if n>=3 and k not in NOISE}
    print(f'line-initial guard: {len(KNOWN):,} known-cited titles')
    st=json.load(open(STATE,encoding='utf-8')) if os.path.exists(STATE) else {}
    todo=[w.strip() for w in a.works.split(',') if w.strip()] or sorted(
        w for w in os.listdir(LEISHU) if os.path.isdir(os.path.join(LEISHU,w)))
    import time; t0=time.time()
    for w in todo:
        if w in st: continue
        if time.time()-t0 > a.budget: print('  (budget reached)'); break
        r=scan(w, titles, KNOWN, VOC)
        if r is None: continue
        st[w]=r
        os.makedirs(os.path.dirname(STATE),exist_ok=True)
        json.dump(st, open(STATE,'w',encoding='utf-8'), ensure_ascii=False)
        print('  {:22s} files={:5d} resolved={:6d} unresolved={:6d}'.format(
            w, r['files'], sum(r['hits'].values()), sum(r['miss'].values())))
    rows=[]; un=collections.Counter(); unby=collections.defaultdict(set)
    for w,r in st.items():
        for cited,n in r['hits'].items():
            rows.append(dict(leishu=w, cited_work=cited, citations=n,
                             match=r['how'].get(cited,''), resolved=1))
        for h,n in r['miss'].items():
            un[h]+=n; unby[h].add(w)
    rows.sort(key=lambda x:(x['leishu'], -x['citations']))
    with open(os.path.join(CORPUS,'index_leishu_徵引.csv'),'w',encoding='utf-8-sig',newline='') as f:
        wtr=csv.DictWriter(f,fieldnames=['leishu','cited_work','citations','match','resolved'])
        wtr.writeheader(); wtr.writerows(rows)
    with open(os.path.join(CORPUS,'index_leishu_徵引_未詳.csv'),'w',encoding='utf-8-sig',newline='') as f:
        wtr=csv.writer(f); wtr.writerow(['cited_head','citations','leishu_count','leishu'])
        for h,n in un.most_common():
            wtr.writerow([h,n,len(unby[h]),'；'.join(sorted(unby[h])[:6])])
    # category context: leishu x its own category path x cited work
    crows=[]
    for w,r in st.items():
        vw=VOC.get(lkey(w),{})
        for key,n in r.get('bycat',{}).items():
            path,cited=key.split('\t',1)
            crows.append(dict(leishu=w, category_path=path,
                              category_leaf=path.split(' > ')[-1],
                              cited_work=cited, citations=n,
                              genmoku=1 if vocab_heading(path.split(' > ')[-1], vw) else 0))
    crows.sort(key=lambda x:(x['leishu'], x['category_path'], -x['citations']))
    with open(os.path.join(CORPUS,'index_leishu_徵引_分類.csv'),'w',encoding='utf-8-sig',newline='') as f:
        wtr=csv.DictWriter(f,fieldnames=['leishu','category_path','category_leaf',
                                         'cited_work','citations','genmoku'])
        wtr.writeheader(); wtr.writerows(crows)
    _cc=sum(r['citations'] for r in crows)
    print(f'\nleishu scanned : {len(st)}')
    print(f'categorised    : {len(crows):,} rows, {_cc:,} citations '
          f'({_cc*100//max(sum(x["citations"] for x in rows),1)}% of attested), '
          f'{len({r["category_path"] for r in crows}):,} distinct paths')
    print(f'attestations   : {len(rows)} pairs, {sum(r["citations"] for r in rows):,} citations')
    print(f'unresolved     : {len(un)} heads, {sum(un.values()):,} citations')

if __name__=='__main__': main()
