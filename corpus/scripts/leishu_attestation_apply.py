# -*- coding: utf-8 -*-
"""Write leishu attestation, with its category context, into each work's metadata.

leishu_attestation.py answers "which leishu quote this work, and how often".
This script answers the follow-on question — "under which of that leishu's own
categories" — and records the pair on the cited work, so a leishu's taxonomy can
be folded onto ordinary works instead of living only in the workbook.

Inputs
  ~/leishu/attest_state.json          per-leishu scan results, incl. `bycat`
  corpus/.metadata_id_registry.csv    title -> corpus path
Outputs (in place)
  <work>/metadata.json    "leishu_attestation"      on every cited work
  <leishu>/metadata.json  "leishu_citation_summary" on the 63 leishu themselves

`raw/` trees are deprecated and never touched. 維基大典 / 礦藝大典 are modern wiki
roots: a page there is an article ABOUT a work, not a witness of it, so it is not
a legitimate target for a pre-modern citation record either.

Run with --dry-run first; --limit N restricts the write for a spot check.
"""
from __future__ import annotations
import argparse, collections, csv, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from leishu_attestation import load_genmoku, vocab_heading, lkey

HOME=os.path.expanduser('~')
REPO=os.path.join(HOME,'mnt/fanyahanwen-corpus')
CORPUS=os.path.join(REPO,'corpus')
STATE=os.path.join(HOME,'leishu','attest_state.json')
REGISTRY=os.path.join(CORPUS,'.metadata_id_registry.csv')
MODERN_ROOTS=('維基大典/','礦藝大典/')
TODAY=time.strftime('%Y-%m-%d')
METHOD=('corpus/scripts/leishu_attestation.py — 曰/云 head, bracket-note and '
        'line-initial idioms; category context from indentation depth, or from '
        'the work\u2019s own 原目 where the transcription is flat')
TOP_CATS=20      # per leishu, per cited work
TOP_LEAVES=40    # rolled up across all leishu


def load_registry():
    """title -> [corpus-relative paths], clean trees only."""
    reg=collections.defaultdict(list)
    with open(REGISTRY, encoding='utf-8-sig') as f:
        for r in csv.DictReader(f):
            if r['kind']!='work' or r.get('status')!='active': continue
            p=r['path'].replace('\\','/')
            if '/raw/' in p or p.startswith('raw/'): continue
            if p.startswith(MODERN_ROOTS): continue
            reg[r['title']].append(p)
    return reg


# A classic is often held only in its commentated edition: the leishu cites 儀禮,
# the corpus holds 儀禮註疏. This is a closed suffix list on purpose — free prefix
# matching is what once folded 三國典略 into 三國.
COMM=('註疏','注疏','正義','集解','集註','集注','章句','傳','注','註','疏')

def widen(title, reg):
    """Registry paths for a cited title, falling back to its commentated edition."""
    if title in reg: return reg[title]
    for c in COMM:
        if title+c in reg: return reg[title+c]
    return []


def invert(st):
    """cited work -> leishu -> {citations, match, cats{path: n}}"""
    out=collections.defaultdict(dict)
    for leishu, r in st.items():
        cats=collections.defaultdict(collections.Counter)
        for key, n in r.get('bycat', {}).items():
            path, cited = key.split('\t', 1)
            cats[cited][path]+=n
        for cited, n in r['hits'].items():
            out[cited][leishu]=dict(citations=n,
                                    match=r['how'].get(cited, ''),
                                    cats=dict(cats.get(cited, {})))
    return out


VOC={}

def confirmed(leishu, path):
    """True when the leaf label is one the work's own 原目 actually lists.

    Indentation alone cannot tell a 子目 from a short line of prose, so a path
    like 「禮盖自伯禽始也 > 博弈嬉戯部四十八」 gets through. Where the 原目 has been
    extracted it settles the question; where it has not, the flag is false and
    means "unverified", not "wrong".
    """
    vw=VOC.get(lkey(leishu))
    if not vw: return False
    return bool(vocab_heading(path.split(' > ')[-1], vw))


def block(byleishu):
    total=sum(v['citations'] for v in byleishu.values())
    leaves=collections.Counter()
    rows=[]; gk=collections.Counter()
    for leishu in sorted(byleishu, key=lambda k:(-byleishu[k]['citations'], k)):
        v=byleishu[leishu]
        cats=sorted(v['cats'].items(), key=lambda kv:(-kv[1], kv[0]))
        for path, n in cats:
            leaves[path.split(' > ')[-1]]+=n
        rows.append({
            'leishu': leishu,
            'citations': v['citations'],
            'match': v['match'],
            'category_count': len(cats),
            'categories': [{'path': p, 'citations': n,
                            'genmoku_confirmed': confirmed(leishu, p)}
                           for p, n in cats[:TOP_CATS]],
        })
        gk[leishu]=sum(n for p, n in cats if confirmed(leishu, p))
    return {
        'schema_version': 1,
        'generated': TODAY,
        'method': METHOD,
        'citations': total,
        'leishu_count': len(byleishu),
        'categorised_citations': sum(leaves.values()),
        'genmoku_confirmed_citations': sum(gk.values()),
        'category_leaves': [{'label': l, 'citations': n}
                            for l, n in leaves.most_common(TOP_LEAVES)],
        'by_leishu': rows,
    }


def write_json(path, doc):
    txt=json.dumps(doc, ensure_ascii=False, indent=2)+'\n'
    with open(path, 'w', encoding='utf-8-sig', newline='\n') as f:
        f.write(txt)


def patch(path, key, value, dry):
    """Set one top-level key on an existing metadata.json, leaving the rest alone.

    A registry path with no directory behind it is a staging artefact of the
    in-progress Han regionalisation, not a work to create — nothing is written
    and no folder is invented.
    """
    if not os.path.isdir(os.path.dirname(path)): return 'path-not-on-disk'
    if not os.path.exists(path): return 'no-metadata-file'
    with open(path, encoding='utf-8-sig') as f:
        try: doc=json.load(f)
        except ValueError: return 'unparseable'
    if doc.get(key)==value: return 'unchanged'
    doc[key]=value
    if not dry: write_json(path, doc)
    return 'written'


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--limit', type=int, default=0)
    a=ap.parse_args()

    global VOC
    VOC=load_genmoku()
    st=json.load(open(STATE, encoding='utf-8'))
    reg=load_registry()
    inv=invert(st)
    print(f'{len(st)} leishu, {len(inv):,} cited works, '
          f'{sum(sum(v["citations"] for v in d.values()) for d in inv.values()):,} citations')

    tally=collections.Counter(); unplaced=[]
    for i, cited in enumerate(sorted(inv)):
        paths=widen(cited, reg)
        if not paths:
            unplaced.append(cited); tally['no-path']+=1; continue
        blk=block(inv[cited])
        for p in paths:
            tally[patch(os.path.join(CORPUS, p, 'metadata.json'),
                        'leishu_attestation', blk, a.dry_run)]+=1
        if a.limit and i+1>=a.limit: break

    # the reverse view, on the leishu themselves
    for leishu, r in sorted(st.items()):
        cats=collections.Counter()
        for key, n in r.get('bycat', {}).items(): cats[key.split('\t')[0]]+=n
        summary={
            'schema_version': 1,
            'generated': TODAY,
            'method': METHOD,
            'works_attested': len(r['hits']),
            'citations': sum(r['hits'].values()),
            'categorised_citations': sum(cats.values()),
            'distinct_categories': len(cats),
            'unresolved_heads': len(r['miss']),
        }
        for p in reg.get(leishu, []):
            tally['leishu:'+patch(os.path.join(CORPUS, p, 'metadata.json'),
                                  'leishu_citation_summary', summary, a.dry_run)]+=1

    print('dry run' if a.dry_run else 'written')
    for k, n in tally.most_common(): print(f'  {k:24s} {n:6d}')
    if unplaced:
        print(f'  cited works with no corpus path: {len(unplaced)}')
        print('   ', '、'.join(sorted(unplaced)[:20]))


if __name__=='__main__': main()
