"""Offline, read-only evaluation of unassigned Points; never writes to the DB.

Uses lcc_llama_probe compiled against the app's macOS llama framework. Captures
raw replies separately. Fixed sampling seed differs from the random app seed.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import subprocess
import textwrap

import sqlite3

parser = argparse.ArgumentParser()
parser.add_argument('--model', required=True)
parser.add_argument('--runner', default='/tmp/pointverse-lcc-llama-probe')
parser.add_argument('--database', default='test-mode/pointverse-test.sqlite')
parser.add_argument('--output', default='/tmp/pointverse-qwen-lcc-eval')
parser.add_argument('--limit', type=int, default=10)
parser.add_argument('--mode', choices=['baseline','simple','simple-clean','theme','theme-app'], default='baseline')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = Path(args.output); out.mkdir(parents=True, exist_ok=True)
catalog = json.loads((root/'ios/PointVerseKit/Sources/PointVerseKit/Resources/lcc-outline.json').read_text())
terms = {x['id']: x for x in catalog['terms']}
catalog_source = (root/'ios/PointVerseKit/Sources/PointVerseKit/Domain/LCCCatalog.swift').read_text()
def dictionary(name):
    block = catalog_source.split('private static let '+name+':', 1)[1].split('\n    ]', 1)[0]
    return {k: v for k, v in re.findall(r'"([^"\n]+)": "([^"\n]+)"', block)}
aliases = dictionary('friendlyNames'); translations = dictionary('translations')
def friendly(term): return aliases.get(term['code'], translations.get(term['code'],term['englishTitle']))
def belongs(id, parent):
    while id:
        if id == parent: return True
        id = terms.get(id, {}).get('parentID')
    return False
instruction_source = (root/'ios/PointVerseKit/Sources/PointVerseKit/Domain/LCCSemanticClassification.swift').read_text()
instruction = textwrap.dedent(re.search(r'public static let judgeInstruction = """\n(.*?)\n    """', instruction_source, re.S).group(1)).strip()
generator_source = (root/'ios/PointVerseApp/Features/PointDetail/QwenTitleGenerator.swift').read_text()
extra = re.search(r'let instruction = LCCSemanticClassification.judgeInstruction \+ (".*")', generator_source)
instruction += json.loads(extra.group(1)) if extra else '\n本任务只选1个。先按主要话题选择宽泛领域，不要求内容是专业论文。仅空白、无实质信息或完全无法理解时才返回uncertain。细分类不确定时选择给出的上级ID，不要放弃整个分类。'
theme_source = (root/'ios/PointVerseKit/Sources/PointVerseKit/Domain/PointThemeClassifier.swift').read_text() if args.mode == 'theme-app' else ''
theme_instruction = json.loads(re.search(r'public static let instruction = (".*")', theme_source).group(1)) if theme_source else ''

db = sqlite3.connect(Path(args.database).resolve().as_uri()+'?mode=ro', uri=True); db.row_factory = sqlite3.Row
db.execute('BEGIN')
rows = db.execute("""SELECT p.id,COALESCE(p.accepted_title,d.title,'') title,TRIM(COALESCE(m.user_text,t.user_text,t.engine_text,'') || ' ' || COALESCE((SELECT GROUP_CONCAT(recognized_text,' ') FROM point_images WHERE point_id=p.id AND recognized_text IS NOT NULL),'')) content FROM points p LEFT JOIN messages m ON m.point_id=p.id AND m.sequence=1 LEFT JOIN audio_assets a ON a.message_id=m.id LEFT JOIN transcripts t ON t.asset_id=a.id LEFT JOIN derivations d ON d.id=(SELECT id FROM derivations WHERE point_id=p.id AND state='succeeded' ORDER BY created_at DESC,rowid DESC LIMIT 1) ORDER BY p.created_at DESC""").fetchall()
reviews = {r['point_id']:json.loads(r['payload']) for r in db.execute('SELECT * FROM lcc_classification_reviews')}
overrides = {r['point_id']:json.loads(r['values_json']) for r in db.execute("SELECT * FROM point_facet_overrides WHERE dimension='domain'")}
hints_block = catalog_source.split('private static let candidateKeywords:',1)[1]
hints = {'lcc:'+k:json.loads('['+v+']') for k,v in re.findall(r'"([A-Z0-9.\-]+)": \[([^\]]*)\]', hints_block)}
def match(text, keyword):
    if all(ord(x)<128 and (x.isalpha() or x==' ') for x in keyword):
        return re.search(r'(?<![a-z0-9_])'+re.escape(keyword)+r'(?![a-z0-9_])', text, re.I) is not None
    return keyword.casefold() in text.casefold()
def unassigned(row):
    if row['id'] in overrides: return not overrides[row['id']]
    text = row['title']+'\n'+row['content']
    return not any(id in terms and any(match(text,k) for k in ks) for id,ks in hints.items())
dataset = [dict(r) for r in rows if unassigned(r)]
dataset.sort(key=lambda r: 0 if reviews.get(r['id'],{}).get('decision',{}).get('status')=='uncertain' else 1)
db.rollback(); db.close()
results_path = out/'results.jsonl'
done = {json.loads(line)['id'] for line in results_path.read_text().splitlines()} if results_path.exists() else set()
metadata = {'model':args.model,'database':str(Path(args.database).resolve()),'unassigned':len(dataset),
    'mode':args.mode,
    'sampling':{'temperature':0.6,'seed':42,'maximumTokens':48 if args.mode=='theme-app' else 360},'context':4096,'batch':128,
    'framework':'same bundled macOS llama framework; text-only ChatML, no projector',
    'instructionSHA256':hashlib.sha256((theme_instruction if args.mode=='theme-app' else instruction).encode()).hexdigest(), 'snapshot':catalog['snapshotID']}
(out/'metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
print(json.dumps(metadata,ensure_ascii=False),flush=True)
stderr = (out/'native.log').open('ab')
process = subprocess.Popen([args.runner,args.model,str(48 if args.mode=='theme-app' else 360)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)

def judge(row, options, parent=None):
    names = '\n'.join(f"{id}: {friendly(terms[id])} / {terms[id]['englishTitle'][:100]}" for id in options)
    stage = f'已经确定大类为{parent}。尝试细分；无法确定细类就继续选择{parent}。' if parent else '从全部21个大类选择最合适的1个，下一步才细分。'
    text = (row['title']+'\n'+row['content'])[:600]
    user = f'{stage}\n可选目录：\n{names}\n内容（前600字符）：\n{text}'
    system=instruction
    if args.mode != 'baseline':
        if args.mode == 'simple-clean':
            for suffix in ['，下一步需要设计一个小实验','，我想先理解它背后的原理']:
                if text.endswith(suffix): text=text[:-len(suffix)]
        names='\n'.join(f"{terms[id]['code']}={friendly(terms[id])}" for id in options)
        system='你给个人笔记按主要话题分类。只选下面目录中最贴切的一个字母。关注句子在谈什么，不要按句尾的计划、实验、理解等通用措辞分类。只输出一个字母，不输出解释、JSON或类别名称。'
        user=f'目录：\n{names}\n笔记：{text}\n分类字母：'
        if args.mode in ('theme', 'theme-app'):
            system=theme_instruction if args.mode=='theme-app' else '你帮助用户整理笔记。判断笔记的主要话题，用一个日常中文主题名称回答，例如天文、园艺、烹饪、历史、沟通、旅行、运动。不需要分类号，不要解释。忽略“下一步需要设计一个小实验”等通用尾句。'
            user=f'笔记：{text}\n主题：'
    prompt = f'<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n'
    data = prompt.encode(); process.stdin.write(str(len(data)).encode()+b'\n'+data); process.stdin.flush()
    line = process.stdout.readline().decode().rstrip('\n')
    if not line: raise RuntimeError(f'Native runner exited: {process.poll()}; see native.log')
    parts=line.split('\t')
    if parts[0]!='OK': return {'error':line,'status':'failed','ids':[]}
    raw=bytes.fromhex(parts[4]).decode(errors='replace')
    result={'raw':raw,'inputTokens':int(parts[1]),'outputTokens':int(parts[2]),'milliseconds':int(parts[3])}
    if args.mode in ('theme', 'theme-app'):
        result.update(status='theme_output',ids=[],reason=raw.strip())
        return result
    try:
        clean=raw.strip()
        if args.mode != 'baseline' and clean in [terms[id]['code'] for id in options]:
            result.update(status='suggested',ids=['lcc:'+clean],reason='实验：只输出大类字母')
            return result
        if clean.startswith('```'): clean=clean.split('\n',1)[1].rsplit('```',1)[0].strip()
        if not clean.startswith('{'): clean=clean[clean.index('{'):clean.rindex('}')+1]
        parsed=json.loads(clean)
        ids=[id.strip() if id.strip().startswith('lcc:') else 'lcc:'+id.strip() for id in parsed.get('ids',[])]
        status=parsed.get('status', 'suggested' if ids else None)
        reason=parsed.get('reason','根据内容主要话题提出的分类建议，待你确认。')
        assert status in ('suggested','uncertain','candidateGap')
        assert len(ids)<=2 and len(set(ids))==len(ids) and all(id in options for id in ids)
        assert not any(x!=y and belongs(x,y) for x in ids for y in ids)
        assert isinstance(reason,str) and 0<len(reason.strip()) and len(reason)<=800
        assert bool(ids)==(status=='suggested')
        result.update(status=status,ids=ids,reason=reason)
    except Exception as error: result.update(status='failed',ids=[],error='parse: '+repr(error))
    return result

try:
    for index,row in enumerate(dataset[:args.limit]):
        if row['id'] in done: continue
        print(f"START {index+1}/{min(args.limit,len(dataset))} {row['id'][:8]} {row['content'][:48]}",flush=True)
        options=[id for id,t in terms.items() if t['parentID'] is None]
        broad=judge(row,options)
        fine=None; final=broad
        if args.mode=='baseline' and broad['status']=='suggested':
            parent=broad['ids'][0]
            options=[id for id in terms if belongs(id,parent)]
            if len(options)>1:
                fine=judge(row,options,parent)
                if fine['status']=='suggested': final=fine
        record={**row,'oldReview':reviews.get(row['id']),'broad':broad,'fine':fine,'final':final}
        with results_path.open('a') as f: f.write(json.dumps(record,ensure_ascii=False)+'\n')
        print(f"DONE {index+1} {final['status']} {final.get('ids')} {final.get('reason',final.get('error'))}",flush=True)
finally:
    process.stdin.close(); process.wait(); stderr.close()
records=[json.loads(line) for line in results_path.read_text().splitlines()]
print('SUMMARY '+json.dumps(dict(collections.Counter(r['final']['status'] for r in records)),ensure_ascii=False),flush=True)
