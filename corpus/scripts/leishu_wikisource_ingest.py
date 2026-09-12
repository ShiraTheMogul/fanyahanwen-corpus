#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
leishu_wikisource_ingest.py — ingest the missing 類書 from zh.wikisource
straight into the corpus tree.

Reuses the PROVEN extraction from rescrape_four_wikisource_works.py (v7):
its html_to_text_inline_preserving walker is what stops 《\\n山海經\\n》 and
〈\\n校記\\n〉 being split across lines. Do not substitute the older
skqs_scraper.py extraction — that one silently writes EMPTY files when
extraction fails, which is what produced the 934 empty 冊府元龜 placeholders
already in the corpus.

Rules this script enforces:
  1. NEVER write an empty or boilerplate-only file. Skip and log instead.
     An absent file is recoverable; a 216-byte placeholder looks like data.
  2. Full metadata header on every file (the corpus header schema).
  3. NO document_id. The repo's corpus_metadata_ids:repair task owns global ID
     allocation against the Git-LFS registry; a second allocator would desync it.
     Run that task after ingesting.
  4. Resumable: an existing non-empty file is left alone unless --overwrite.
  5. UTF-8 with BOM on every text file; Han filenames stay literal Unicode.

Usage:
  leishu_wikisource_ingest.py --list
  leishu_wikisource_ingest.py --works 玉海 --limit 60
  leishu_wikisource_ingest.py --works 冊府元龜 --overwrite-empty --limit 100
"""
from __future__ import annotations
import argparse, importlib.util, json, os, re, sys, time
from datetime import datetime, timezone

HOME = os.path.expanduser('~')
REPO = os.path.join(HOME, 'mnt/fanyahanwen-corpus')
CORPUS = os.path.join(REPO, 'corpus')
V7 = os.path.join(CORPUS, 'scripts', 'rescrape_four_wikisource_works.py')

_spec = importlib.util.spec_from_file_location('v7', V7)
v7 = importlib.util.module_from_spec(_spec)
_argv = sys.argv; sys.argv = ['v7']
_spec.loader.exec_module(v7)
sys.argv = _argv

API = 'https://zh.wikisource.org/w/api.php'
BOM_ENC = 'utf-8-sig'
EMPTY_MIN = 400          # bytes; below this a file is boilerplate, not content

# work -> wikisource root, corpus dynasty folder, author, times.
# Author/date come from 類書研究清單 where that sheet records them as verified.
# Where the sheet does not establish an author, the field is left EMPTY —
# never guessed.
WORKS = {
 '冊府元龜':      dict(root='冊府元龜',                      dyn='北宋', author='王欽若', times='1013年', note='repair: 934 of 985 existing files are empty placeholders'),
 '北堂書鈔':      dict(root='北堂書鈔 (四庫全書本)',          dyn='隋朝', author='虞世南', times=''),
 '玉海':          dict(root='玉海 (四庫全書本)',              dyn='南宋', author='王應麟', times=''),
 '小學紺珠':      dict(root='小學紺珠 (四庫全書本)',          dyn='南宋', author='王應麟', times=''),
 '事類賦':        dict(root='事類賦 (四庫全書本)',            dyn='北宋', author='吳淑',   times=''),
 '圖書編':        dict(root='圖書編 (四庫全書本)',            dyn='明朝', author='章潢',   times=''),
 '格致鏡原':      dict(root='格致鏡原 (四庫全書本)',          dyn='清朝', author='陳元龍', times=''),
 '經濟類編':      dict(root='經濟類編 (四庫全書本)',          dyn='明朝', author='馮琦',   times=''),
 '御定子史精華':  dict(root='御定子史精華 (四庫全書本)',      dyn='清朝', author='',       times='1727年'),
 '御定淵鑑𩔖函':  dict(root='御定淵鑑𩔖函 (四庫全書本)',      dyn='清朝', author='',       times='1710年'),
 '御定駢字類編':  dict(root='御定駢字類編 (四庫全書本)',      dyn='清朝', author='',       times='1719年'),
 '山堂肆考':      dict(root='山堂肆考 (四庫全書本)',          dyn='明朝', author='彭大翼', times=''),
 '白孔六帖':      dict(root='白孔六帖 (四庫全書本)',          dyn='南宋', author='',       times='', note='白居易原本＋孔傳續撰，合編者不詳'),
 '錦繡萬花谷':    dict(root='錦繡萬花谷 (四庫全書本)',        dyn='南宋', author='',       times='1188年'),
 '天中記':        dict(root='天中記 (四庫全書本)',            dyn='明朝', author='',       times=''),
 '古今事文類聚':  dict(root='古今事文類聚 (四庫全書本)',      dyn='南宋', author='',       times=''),
 '記纂淵海':      dict(root='記纂淵海 (四庫全書本)',          dyn='南宋', author='',       times=''),
 '古儷府':        dict(root='古儷府 (四庫全書本)',            dyn='明朝', author='',       times=''),
 '廣博物志':      dict(root='廣博物志 (四庫全書本)',          dyn='明朝', author='董斯張', times=''),
 '埤雅':          dict(root='埤雅 (四庫全書本)',              dyn='北宋', author='',       times=''),
 '通雅':          dict(root='通雅 (四庫全書本)',              dyn='明朝', author='',       times=''),
 '初學記':        dict(root='初學記 (四庫全書本)',            dyn='唐朝', author='徐堅',   times=''),
 '羣書㑹元截江網':dict(root='羣書㑹元截江網 (四庫全書本)',    dyn='南宋', author='',       times='', note='匿名編者；胡助為元刊本作序，非作者'),
 '武備志':        dict(root='武備志',                          dyn='明朝', author='茅元儀', times='1621年'),
}

def api(params):
    import requests
    params = dict(params); params.setdefault('format','json'); params.setdefault('formatversion',2)
    for attempt in range(4):
        try:
            r = requests.get(API, params=params, headers=v7.HEADERS, timeout=45)
            r.raise_for_status(); return r.json()
        except Exception:
            if attempt == 3: raise
            time.sleep(1.5*(attempt+1))

def subpages(root):
    out, cont = [], None
    while True:
        p = dict(action='query', list='allpages', apprefix=root+'/', aplimit=500, apnamespace=0)
        if cont: p['apcontinue'] = cont
        d = api(p)
        out += [x['title'] for x in d.get('query',{}).get('allpages',[])]
        cont = d.get('continue',{}).get('apcontinue')
        if not cont: break
    # 全覽 pages duplicate whole volumes; 目録 pages are catalogues, keep those
    return sorted(t for t in out if not re.search(r'全覽|全览', t))

def juan_key(title):
    tail = title.split('/')[-1]
    n = re.findall(r'(\d+)', tail)
    return (0 if re.search(r'目[録錄]', tail) else 1, int(n[0]) if n else 0, tail)

def existing_map(raw_dir, work):
    """Map wikisource PAGE_TITLE -> existing corpus filename.

    Works already in the corpus have their own filename convention
    (冊府元龜__juan_02.txt). Repairing them must write BACK to those names,
    or the repair silently becomes a duplicate set of files alongside the
    broken ones. The mapping is read from each file's own header.
    """
    out = {}
    if not os.path.isdir(raw_dir): return out
    for fn in os.listdir(raw_dir):
        if not fn.endswith('.txt'): continue
        try:
            with open(os.path.join(raw_dir, fn), encoding=BOM_ENC, errors='replace') as f:
                head = f.read(400)
        except Exception:
            continue
        m = re.search(r'^#\s*PAGE_TITLE:\s*(.+)$', head, re.M)
        if m: out[m.group(1).strip()] = fn
    return out

def local_name(work, title, seq):
    tail = title.split('/')[-1]
    stub = re.sub(r'[\\/:*?"<>|]', '_', tail)
    return f'{work}__{seq:04d}__{stub}.txt'

def header(work, meta, page_title, url, cats):
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    lines = [
      f'# WORK_TITLE: {work}', f'# DISPLAY_TITLE: {work}',
      f'# PAGE_TITLE: {page_title}', f"# AUTHOR: {meta.get('author','')}",
      f"# NATION: {meta['dyn']}", f"# TIMES: {meta.get('times','')}",
      f'# CATEGORIES: 類書', f'# WS_CATEGORIES: {cats}',
      f'# SOURCE_URL: {url}', f'# SCRAPED_AT_UTC: {now}', '']
    return '\n'.join(lines) + '\n'

def ingest(work, limit, overwrite_empty, sleep):
    meta = WORKS[work]
    raw_dir   = os.path.join(CORPUS, '中國漢文', 'raw',   meta['dyn'], work)
    clean_dir = os.path.join(CORPUS, '中國漢文', 'clean', meta['dyn'], work)
    os.makedirs(raw_dir, exist_ok=True); os.makedirs(clean_dir, exist_ok=True)
    state_p = os.path.join(HOME, 'leishu', f'ingest_{work}.json')
    state = json.load(open(state_p, encoding='utf-8')) if os.path.exists(state_p) else {}
    titles = state.get('titles') or subpages(meta['root'])
    titles.sort(key=juan_key)
    state['titles'] = titles
    done = set(state.get('done', [])); empty = set(state.get('empty', []))
    existing = existing_map(raw_dir, work)
    if existing:
        print(f'    [{work}] {len(existing)} existing files found; repairing in place '
              f'under their own filenames')
    def save():
        state['done']=sorted(done); state['empty']=sorted(empty)
        os.makedirs(os.path.dirname(state_p), exist_ok=True)
        json.dump(state, open(state_p,'w',encoding='utf-8'), ensure_ascii=False)
    n_new = n_empty = n_skip = 0
    for seq, t in enumerate(titles, 1):
        if n_new + n_empty >= limit: break
        fn = existing.get(t) or local_name(work, t, seq)
        rp, cp = os.path.join(raw_dir, fn), os.path.join(clean_dir, fn)
        if (n_new + n_empty) and (n_new + n_empty) % 25 == 0: save()
        if t in empty:                      # known blank on Wikisource; don't refetch
            n_skip += 1; continue
        if t in done and os.path.exists(cp) and os.path.getsize(cp) >= EMPTY_MIN:
            n_skip += 1; continue
        if os.path.exists(cp) and os.path.getsize(cp) >= EMPTY_MIN and not overwrite_empty:
            done.add(t); n_skip += 1; continue
        try:
            html = v7.fetch_html_for_page(t)
            body = v7.clean_html_to_text(html) if html else ''
        except Exception as e:
            print(f'    !! {t}: {type(e).__name__}: {e}'); body = ''
        if len(body.strip()) < 40:
            # RULE 1: never write a placeholder. This is the 冊府元龜 defect.
            n_empty += 1; empty.add(t)
            print(f'    -- empty, NOT written: {t}')
            time.sleep(sleep); continue
        try:
            cats = '；'.join(v7.fetch_categories_for_page(t, root_title=meta['root'])[0])
        except Exception:
            cats = ''
        url = 'https://zh.wikisource.org/wiki/' + t.replace(' ', '_')
        hdr = header(work, meta, t, url, cats)
        for path, payload in ((rp, hdr + body), (cp, hdr + body)):
            with open(path, 'w', encoding=BOM_ENC, newline='\n') as f:
                f.write(payload)
        done.add(t); n_new += 1
        print(f'    ok {t}  ({len(body)} chars)')
        time.sleep(sleep)
    state['done'] = sorted(done); state['empty'] = sorted(empty)
    os.makedirs(os.path.dirname(state_p), exist_ok=True)
    json.dump(state, open(state_p,'w',encoding='utf-8'), ensure_ascii=False)
    # metadata.json in the corpus shape, deliberately WITHOUT document_id
    docs = []
    for seq, t in enumerate(titles, 1):
        fn = existing.get(t) or local_name(work, t, seq)
        if os.path.exists(os.path.join(clean_dir, fn)) or os.path.exists(os.path.join(raw_dir, fn)):
            docs.append({'file': fn,
                         'path': f'中國漢文/raw/{meta["dyn"]}/{work}/{fn}',
                         'sequence': seq, 'page_title': t})
    json.dump({'schema_version':1,'title':work,'corpus_root':'中國漢文','documents':docs},
              open(os.path.join(raw_dir,'metadata.json'),'w',encoding='utf-8'),
              ensure_ascii=False, indent=2)
    remaining = len(titles) - len(done) - len(empty)
    print(f'[{work}] pages={len(titles)} written_now={n_new} empty_skipped={n_empty} '
          f'already={n_skip} remaining={remaining}')
    return remaining

if __name__ == '__main__':
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument('--works', default='')
    ap.add_argument('--limit', type=int, default=60)
    ap.add_argument('--sleep', type=float, default=0.4)
    ap.add_argument('--overwrite-empty', action='store_true')
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    if a.list:
        for k,v in WORKS.items(): print(f'{k:16s} {v["root"]}')
        sys.exit(0)
    names = [w.strip() for w in a.works.split(',') if w.strip()] or list(WORKS)
    for w in names:
        if w not in WORKS: print(f'?? unknown work {w}'); continue
        ingest(w, a.limit, a.overwrite_empty, a.sleep)
