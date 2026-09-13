# -*- coding: utf-8 -*-
"""Rebuild the folded category index, and score which folded names can merge.

合併分類 was built when 類書分類原目 held 1,896 rows; it now holds 18,784, and the
citation scan has since attached a real category path to 89,917 quotations. This
script re-folds the whole taxonomy and replaces the sheet's hand-sampled evidence
columns with what the leishu actually quote under each heading.

Folding follows the rules the workbook already documents:
  · terminal 部 / 類 / 庫 are taxonomy markers, dropped from the comparison key
  · bracketed 附 / 屬 commentary never enters the candidate name
  · graph variants are folded for comparison only (嵗→歲, 寳→寶, 産→產, 厯→曆, …)
  · volume suffixes 上 / 中 / 下 and 一…百 are dropped (天部下, 人部五十二 → 天, 人)

Every human decision already recorded on a folded row — merge status, navigation
action and target, decision confidence and basis — is carried across unchanged.
A rebuild must never quietly discard a judgement someone made.

Outputs (all in fanya_category_grouping_2026-09-11.xlsx):
  合併分類   rebuilt, one row per folded name
  合併候選   NEW — folded pairs whose cited-work profiles overlap
"""
import argparse, collections, csv, math, re
import openpyxl
from openpyxl.styles import Font, Alignment
from openpyxl.utils import get_column_letter

WB='fanya_category_grouping_2026-09-11.xlsx'
CIT='corpus/index_leishu_徵引_分類.csv'

VAR=str.maketrans('嵗寳産厯𩔖巻増荘説畧尓応躰虫閒䇿逺諌','歲寶產曆類卷增莊說略爾應體蟲間策遠諫')
BRACK=re.compile(r'[（(〈《【\[][^）)〉》】\]]*[）)〉》】\]]')
NUM=re.compile(r'(?:第)?[一二三四五六七八九十百千]+$')
UD=re.compile(r'[上中下]$')
MARK=re.compile(r'[部類庫]$')


def fold(label):
    """The comparison key for a source heading."""
    s=re.sub(r'\s+','', BRACK.sub('', str(label)).strip()).translate(VAR)
    prev=None
    while s and s!=prev:
        prev=s
        for rx in (NUM, UD, MARK):
            t=rx.sub('', s)
            if t: s=t
    return s


def band(nworks):
    return ('A' if nworks>=8 else 'B' if nworks>=5 else 'C' if nworks>=3
            else 'D' if nworks==2 else 'E')


def load_genmoku(wb):
    ws=wb['類書分類原目']; it=ws.iter_rows(values_only=True); hdr=list(next(it))
    out=[]
    for r in it:
        if not r or not r[1]: continue
        d=dict(zip(hdr, r))
        lab=(d.get('Exact source label') or d.get('Subdivision') or '')
        if not str(lab).strip(): continue
        d['_label']=str(lab).strip(); d['_fold']=fold(lab)
        if d['_fold']: out.append(d)
    return out


def load_citations():
    """folded category -> {cited work: citations}, and per-leishu attestation."""
    prof=collections.defaultdict(collections.Counter)
    conf=collections.Counter(); tot=collections.Counter()
    seen=collections.defaultdict(set)
    for r in csv.DictReader(open(CIT, encoding='utf-8-sig')):
        # Every segment of the path, not only the leaf. A 部-level name such as
        # 職官 or 歲時 almost never IS a leaf — its citations all sit under its 子目 —
        # so keying on the leaf alone leaves the umbrellas with empty profiles and
        # no umbrella pair can ever be compared.
        segs={fold(x) for x in r['category_path'].split(' > ')}
        segs.discard('')
        if not segs: continue
        n=int(r['citations']); w=r['cited_work']
        for k in segs:
            prof[k][w]+=n
            tot[k]+=n
            seen[k].add(r['leishu'])
            if r['genmoku']=='1': conf[k]+=n
    return prof, tot, conf, seen


def keep_decisions(ws):
    """Existing human judgements, keyed by folded category.

    Also keeps the descriptive columns, so that a decision whose folded name no
    longer appears in the rebuilt taxonomy can be re-emitted intact instead of
    disappearing. A folding change must not be able to delete a judgement.
    """
    hdr=[c.value for c in ws[1]]
    idx={h:i for i,h in enumerate(hdr) if h}
    want=['Merge status','Navigation action','Navigation target',
          'Decision confidence','Decision basis','Notes',
          'Raw forms','Canonical destinations','Source attestations','Source URLs',
          'Distinct works','Raw rows','Regions']
    out={}
    for row in ws.iter_rows(min_row=2, values_only=True):
        if not row or not row[0]: continue
        d={w: (row[idx[w]] if idx[w]<len(row) else None) for w in want if w in idx}
        d['_name']=row[0]
        if any(d.get(w) not in (None,'') for w in
               ('Merge status','Navigation action','Decision basis')):
            out[fold(row[0])]=d
    return out, hdr


HDR=['Folded category','Raw forms','Distinct works','Raw rows','Regions',
     'Source levels','Priority band','Direct children count','Direct children',
     'Canonical destination count','Canonical destinations','Merge status',
     'Attesting leishu','徵引次數','原目確認次數','所徵引書數','所徵引之書',
     'Navigation action','Navigation target','Decision confidence',
     'Decision basis','Notes','Source attestations','Source URLs']

# Preserved verbatim from the sheet this rebuild replaces. These are the rules the
# folding above implements; they are restated here because the sheet is the place
# a reader looks for them.
RULES=[('Rule','Terminal 部 / 類 / 庫 are taxonomy markers and are removed from the comparison key.'),
 ('Comments','Bracketed 附 / 屬 commentary is excluded from candidate category names; it remains in 原始分類 notes.'),
 ('Variants','Clear graph variants are folded only for comparison: 嵗→歲, 寳→寶, 産→產, 厯→曆.'),
 ('Geography','Composite 和漢三才圖會 catalogue strings are split into individual place headings; source volume grouping is retained in notes.'),
 ('Priority','A = 8+ works; B = 5–7; C = 3–4; D = 2; E = 1.'),
 ('Ambiguity','context-sensitive means one folded name maps to multiple canonical destinations.'),
 ('Volumes','Volume suffixes are dropped for comparison too: 上 / 中 / 下 and 一…百 (天部下, 人部五十二 → 天, 人).'),
 ('Evidence','徵引 columns come from index_leishu_徵引_分類.csv — what the leishu actually quote under the heading, not a hand sample.'),
 ('原目確認','The share of those citations whose heading the work\u2019s own 原目 confirms. The remainder is unverified, not wrong.')]


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--min-shared', type=int, default=6)
    ap.add_argument('--min-score', type=float, default=0.30)
    ap.add_argument('--min-cit', type=int, default=25)
    a=ap.parse_args()

    wb=openpyxl.load_workbook(WB)
    rows=load_genmoku(wb)
    prof, tot, conf, leishu_seen=load_citations()
    prior, oldhdr=keep_decisions(wb['合併分類'])

    # canonical destinations already assigned in 分類對照
    dest=collections.defaultdict(set)
    ws=wb['分類對照']; hdr=[c.value for c in ws[1]]
    ci={h:i for i,h in enumerate(hdr) if h}
    for r in ws.iter_rows(min_row=2, values_only=True):
        lab=r[ci['Source label']]; path=r[ci['Primary canonical path']]
        if lab and path: dest[fold(lab)].add(path)

    agg=collections.defaultdict(lambda: dict(
        raw=collections.Counter(), works=set(), regions=set(),
        levels=collections.Counter(), n=0, urls=set(), att=[], kids=collections.Counter()))
    for d in rows:
        g=agg[d['_fold']]
        g['raw'][d['_label']]+=1; g['works'].add(d['Work']); g['n']+=1
        if d.get('Region'): g['regions'].add(str(d['Region']))
        if d.get('Source level'): g['levels'][str(d['Source level'])]+=1
        src=str(d.get('Source') or '')
        if src.startswith('http'): g['urls'].add(src)
        if len(g['att'])<40: g['att'].append(f"{d['Work']} — {d['_label']}")
        p=d.get('Parent')
        if p and str(p).strip():
            pk=fold(p)
            if pk and pk!=d['_fold']: agg[pk]['kids'][d['_label']]+=1

    out=[]
    for k, g in agg.items():
        books=prof.get(k, collections.Counter())
        out.append([
            k,
            '\n'.join(sorted(g['raw'])),
            len(g['works']),
            g['n'],
            '\n'.join(sorted(g['regions'])),
            '、'.join(f'{l}({n})' for l, n in g['levels'].most_common()),
            band(len(g['works'])),
            len(g['kids']),
            '；'.join(w for w, _ in g['kids'].most_common(60)),
            len(dest.get(k, ())),
            '\n'.join(sorted(dest.get(k, ()))),
            prior.get(k, {}).get('Merge status'),
            '、'.join(sorted(leishu_seen.get(k, ()))),
            tot.get(k, 0),
            conf.get(k, 0),
            len(books),
            '、'.join(f'{w}({n})' for w, n in books.most_common(15)),
            prior.get(k, {}).get('Navigation action'),
            prior.get(k, {}).get('Navigation target'),
            prior.get(k, {}).get('Decision confidence'),
            prior.get(k, {}).get('Decision basis'),
            prior.get(k, {}).get('Notes'),
            '\n'.join(g['att'][:20]),
            '\n'.join(sorted(g['urls'])[:4]),
        ])
    CIT_I=HDR.index('徵引次數')
    out.sort(key=lambda r:('ABCDE'.index(r[6]), -r[2], -r[CIT_I], r[0]))

    # Decisions whose folded name the current rules no longer produce. 藝術 is one:
    # its only source form is 藝術總部, which folds to 藝術總 here and folded to 藝術
    # before. Rather than retune the rules around a single row — which would unsettle
    # the twenty 總載 rows that fold correctly — the judgement is carried over as an
    # orphan and labelled, so it is reviewed rather than lost.
    orphan=[k for k in prior if k not in agg]
    for k in orphan:
        d=prior[k]
        row=[None]*len(HDR)
        row[0]=d['_name']; row[1]=d.get('Raw forms'); row[2]=d.get('Distinct works')
        row[3]=d.get('Raw rows'); row[4]=d.get('Regions'); row[6]='—'
        row[HDR.index('Canonical destinations')]=d.get('Canonical destinations')
        row[HDR.index('Merge status')]=d.get('Merge status')
        row[HDR.index('Navigation action')]=d.get('Navigation action')
        row[HDR.index('Navigation target')]=d.get('Navigation target')
        row[HDR.index('Decision confidence')]=d.get('Decision confidence')
        row[HDR.index('Decision basis')]=d.get('Decision basis')
        row[HDR.index('Source attestations')]=d.get('Source attestations')
        row[HDR.index('Source URLs')]=d.get('Source URLs')
        row[HDR.index('Notes')]=((str(d.get('Notes') or '')+' | ').lstrip(' |')
            +'孤行：現行折疊規則不再產生此名（原形已折入他處），判定原樣保留待覆核。')
        out.append(row)

    del wb['合併分類']
    ws=wb.create_sheet('合併分類', wb.sheetnames.index('分類對照')+1)
    ws.append(HDR)
    for c in range(1, len(HDR)+1): ws.cell(1, c).font=Font(bold=True)
    for r in out: ws.append(r)
    for i, w in enumerate((16,22,8,8,10,20,6,8,50,8,30,14,26,9,10,9,70,22,22,10,40,30,34,34), 1):
        ws.column_dimensions[get_column_letter(i)].width=w
    ws.freeze_panes='B2'
    ws.auto_filter.ref=f'A1:{get_column_letter(len(HDR))}{ws.max_row}'
    for r in range(2, ws.max_row+1):
        for c in (2, 9, HDR.index('所徵引之書')+1, HDR.index('Source attestations')+1):
            ws.cell(r, c).alignment=Alignment(wrap_text=True, vertical='top')
    # the rule block, in its own labelled columns past the data
    rc=len(HDR)+2
    ws.cell(1, rc, 'How this sheet folds names').font=Font(bold=True)
    ws.column_dimensions[get_column_letter(rc)].width=18
    ws.column_dimensions[get_column_letter(rc+1)].width=96
    for i, (name, text) in enumerate(RULES, start=2):
        ws.cell(i, rc, name); ws.cell(i, rc+1, text)
    ws.cell(len(RULES)+2, rc, 'Raw category rows'); ws.cell(len(RULES)+2, rc+1, len(rows))
    ws.cell(len(RULES)+3, rc, 'Folded rows'); ws.cell(len(RULES)+3, rc+1, len(out))

    # ---- merge candidates from citation overlap -------------------------------
    # Raw overlap does not work. Every 職官 heading quotes 漢書, 後漢書 and 通典, so
    # 太守 and 縣令 score 0.79 while being plainly different offices. Weighting each
    # book by inverse category frequency removes that shared background and leaves
    # the diagnostic books — the ones only a handful of headings quote.
    # Only names the 原目 actually lists may be candidates. Without this the
    # unverified paths in flat transcriptions (事物紀原 yields 「于鑚木造火之後」) pair
    # off against real categories and dominate the top of the list.
    known=set(agg)
    cand=[k for k in prof
          if k in known and tot[k]>=a.min_cit and len(prof[k])>=a.min_shared]
    df=collections.Counter()
    for k in cand:
        for w in prof[k]: df[w]+=1
    N=len(cand)
    idf={w: math.log(N/dfw) for w, dfw in df.items()}
    vec={k: {w: math.sqrt(n)*idf[w] for w, n in prof[k].items()} for k in cand}
    norm={k: math.sqrt(sum(v*v for v in vec[k].values())) or 1.0 for k in cand}

    inv=collections.defaultdict(list)
    for k in cand:
        for w in prof[k]:
            if df[w] <= N*0.10:           # a book a tenth of all headings quote
                inv[w].append(k)          # is background, not evidence
    pair=collections.Counter()
    for w, ks in inv.items():
        for i in range(len(ks)):
            for j in range(i+1, len(ks)):
                pair[tuple(sorted((ks[i], ks[j])))]+=1

    def cosine(p, q):
        x, y = vec[p], vec[q]
        if len(x) > len(y): x, y = y, x
        num=sum(v*y[w] for w, v in x.items() if w in y)
        return num/(norm[p]*norm[q])

    def diagnostic(p, q):
        """Shared books ranked by how few other headings quote them."""
        both=set(prof[p]) & set(prof[q])
        return sorted(both, key=lambda w: (df[w], -(prof[p][w]+prof[q][w])))

    def name_link(p, q):
        common=set(p) & set(q)
        if p in q or q in p: return '包含'
        if common: return '共字：'+''.join(sorted(common))
        return ''

    # Structural relation, tested against the 37 decisions already in 同義判定:
    #   異書異名 (the two names never appear in one work's own taxonomy) — 34 merge
    #     to 15 keep. A compiler who never used both names is not distinguishing them.
    #   同書並列 (both appear in the same work) — 5 merge to 7 keep. That work IS
    #     distinguishing them, so a merge there is a browse umbrella, not a synonym.
    #   父子 — a parent and its own child; hierarchy, not alias.
    # The citation score alone does not separate merge from keep (服飾~服用 scores
    # 0.48 and was kept; 珍寶~寶貨 scores 0.40 and was merged), so 建議 is triage for
    # a human, never a decision.
    def ancestors(k, depth=6):
        seen=set(); frontier={k}
        while frontier and depth:
            depth-=1
            nxt=set()
            for x in frontier:
                for p in parent_of.get(x, ()):
                    if p not in seen: seen.add(p); nxt.add(p)
            frontier=nxt
        return seen

    def relation(p, q):
        if q in ancestors(p) or p in ancestors(q): return '父子'
        if works_of[p] & works_of[q]: return '同書並列'
        return '異書異名'

    def containment(p, q):
        """How much of the smaller heading's reading sits inside the larger one.

        Two names for one thing quote each other's books BOTH ways. A child inside
        a parent quotes a subset: 涇 against 地理 shares almost every book 涇 has,
        and 地理 is many times its size. That is containment, not synonymy.
        """
        shared=len(set(prof[p]) & set(prof[q]))
        small=min(len(prof[p]), len(prof[q])) or 1
        ratio=max(tot[p], tot[q])/max(min(tot[p], tot[q]), 1)
        return shared/small, ratio

    def advise(rel, score, cover, ratio):
        if rel=='父子': return '上下位——宜保留層級'
        if rel=='同書並列': return '同書並列——宜作導覽傘，非同義'
        if cover>=0.85 and ratio>=2.5: return '疑上下位——小者幾全含於大者，可作導覽傘'
        return '同義候選（強）' if score>=0.45 else '同義候選（待核）'

    works_of=collections.defaultdict(set); parent_of=collections.defaultdict(set)
    for d in rows:
        works_of[d['_fold']].add(d['Work'])
        p=d.get('Parent')
        if p and str(p).strip():
            pk=fold(p)
            if pk and pk!=d['_fold']: parent_of[d['_fold']].add(pk)

    decided={}
    ws=wb['同義判定']
    hh=[c.value for c in ws[1]]
    fi_=hh.index('Candidate family'); di_=hh.index('Decision')
    for r in ws.iter_rows(min_row=2, values_only=True):
        if not r or not r[fi_]: continue
        ns=[fold(x.strip()) for x in str(r[fi_]).split('/') if x.strip()]
        for i in range(len(ns)):
            for j in range(i+1, len(ns)):
                decided[tuple(sorted((ns[i], ns[j])))]=str(r[di_])

    scored=[]
    for (p, q), shared in pair.items():
        if shared<a.min_shared: continue
        s=cosine(p, q)
        if s<a.min_score: continue
        same=bool(dest.get(p) and dest.get(p)==dest.get(q))
        diag=diagnostic(p, q)
        rel=relation(p, q)
        cover, ratio=containment(p, q)
        scored.append([p, q, rel, advise(rel, s, cover, ratio),
                       decided.get((p, q), ''),
                       round(s,3), shared, round(cover,2), name_link(p, q),
                       len(prof[p]), len(prof[q]), tot[p], tot[q],
                       '是' if same else '',
                       '\n'.join(sorted(dest.get(p, ()))),
                       '\n'.join(sorted(dest.get(q, ()))),
                       '、'.join(f'{w}({df[w]})' for w in diag[:12]),
                       '、'.join(sorted(leishu_seen.get(p, ()))[:6]),
                       '、'.join(sorted(leishu_seen.get(q, ()))[:6])])
    ORD={'異書異名': 0, '父子': 1, '同書並列': 2}
    scored.sort(key=lambda r:(ORD[r[2]], '疑上下位' in r[3], -r[5], -r[6]))

    CH=['類目甲','類目乙','結構關係','建議（供人工判定，非結論）','已有判定',
        '徵引相似度','共同書數','小者含入率','字面關係','甲書數','乙書數',
        '甲徵引','乙徵引','已同歸一類','甲現有歸類','乙現有歸類',
        '共同徵引之書（括號為該書所見類目數，越小越有辨識力）','甲見於類書','乙見於類書']
    if '合併候選' in wb.sheetnames: del wb['合併候選']
    cs=wb.create_sheet('合併候選', wb.sheetnames.index('合併分類')+1)
    cs.append(CH)
    for c in range(1, len(CH)+1): cs.cell(1, c).font=Font(bold=True)
    for r in scored: cs.append(r)
    for i, w in enumerate((14,14,11,26,26,10,9,10,14,8,8,9,9,10,26,26,70,26,26), 1):
        cs.column_dimensions[get_column_letter(i)].width=w
    cs.freeze_panes='C2'
    for r in range(2, cs.max_row+1):
        cs.cell(r, 17).alignment=Alignment(wrap_text=True, vertical='top')
    cs.auto_filter.ref=f'A1:{get_column_letter(len(CH))}{cs.max_row}'

    wb.save(WB)
    b=collections.Counter(r[6] for r in out)
    print(f'合併分類 : {len(out):,} folded categories from {len(rows):,} 原目 rows')
    print('  bands  :', ', '.join(f'{k}={b[k]}' for k in 'ABCDE'))
    print(f'  with citation evidence : {sum(1 for r in out if r[11]):,}')
    NA=HDR.index('Navigation action')
    carried={r[0] for r in out if r[NA]}
    print(f'  human decisions carried: {len(carried):,} of {len(prior):,}')
    if orphan: print(f'  orphaned decisions carried as marked rows: {len(orphan)} {orphan}')
    assert not (set(prior)-carried), 'a decision was lost'
    print(f'合併候選 : {len(scored):,} pairs (shared>={a.min_shared}, cos>={a.min_score})')
    rc=collections.Counter(r[2] for r in scored)
    print('  relations:', ', '.join(f'{k}={v}' for k, v in rc.most_common()))
    for r in scored[:18]:
        print(f'   {r[0]:8s} ~ {r[1]:8s} {r[2]:5s} cos={r[5]:.2f} n={r[6]:3d} '
              f'含入={r[7]:.2f} {r[3][:22]:24s} {r[4][:18]}')

    # Does the method rediscover the merges a human already made?
    fam=[]
    ws=wb['同義判定']
    hh=[c.value for c in ws[1]]; fi=hh.index('Candidate family'); di=hh.index('Decision')
    lut={(r[0], r[1]): r[5] for r in scored}
    lut.update({(r[1], r[0]): r[5] for r in scored})
    for r in ws.iter_rows(min_row=2, values_only=True):
        if not r or not r[fi]: continue
        names=[fold(x.strip()) for x in str(r[fi]).split('/') if x.strip()]
        for i in range(len(names)):
            for j in range(i+1, len(names)):
                fam.append((names[i], names[j], str(r[di]), lut.get((names[i], names[j]))))
    adv={(r[0], r[1]): r[3] for r in scored}
    adv.update({(r[1], r[0]): r[3] for r in scored})
    demoted=[f for f in fam if '疑上下位' in (adv.get((f[0], f[1])) or '')
             and f[2].startswith('merge')]
    if demoted:
        # Not a contradiction: 「merge as navigation umbrella」 IS a merge of a broad
        # heading with a narrower one, which is what containment detects.
        print('  containment flag on known umbrella merges (consistent, not a miss):',
              '、'.join(f'{d[0]}~{d[1]}' for d in demoted))
    testable=[f for f in fam
              if tot.get(f[0],0)>=a.min_cit and tot.get(f[1],0)>=a.min_cit]
    hit=sum(1 for f in testable if f[3])
    thin=[f for f in fam if f not in testable]
    print(f'同義判定 check: {hit}/{len(testable)} recovered among pairs both sides of '
          f'which clear the {a.min_cit}-citation floor; {len(thin)} pairs untestable '
          f'(one side has too little attested text)')
    for f in testable:
        print(f'   {f[0]} ~ {f[1]:8s} {f[2][:26]:28s} -> ' +
              (f'cos={f[3]}' if f[3] else 'NOT surfaced'))
    if thin:
        print('   untestable: ' + '、'.join(
            f'{f[0]}~{f[1]}' for f in thin[:18]))


if __name__=='__main__': main()
