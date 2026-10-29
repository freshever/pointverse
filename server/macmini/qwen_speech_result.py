"""Format Qwen chunk timings without inventing word alignments or rewriting languages."""
from opencc import OpenCC

LANGUAGES=dict(zip(
    ['chinese','english','cantonese','arabic','german','french','spanish','portuguese','indonesian','italian','korean','russian','thai','vietnamese','japanese','turkish','hindi','malay','dutch','swedish','danish','finnish','polish','czech','filipino','persian','greek','hungarian','macedonian','romanian'],
    ['zh','en','yue','ar','de','fr','es','pt','id','it','ko','ru','th','vi','ja','tr','hi','ms','nl','sv','da','fi','pl','cs','fil','fa','el','hu','mk','ro']))


def format_result(output,duration,token_limit=4096):
    if output.generation_tokens>=token_limit:raise ValueError('speech_token_limit')
    raw_segments=output.segments or []
    if raw_segments and float(raw_segments[-1]['end'])<duration-0.1:raise ValueError('incomplete_speech_output')
    segments=[];raw_parts=[];converter=None;languages=[]
    for item in raw_segments:
        raw=str(item['text']).strip();language=str(item.get('language') or '').lower()
        language=LANGUAGES.get(language,language or 'unknown');text=raw
        if language in ('zh','yue'):
            if converter is None:converter=OpenCC('t2s')
            text=converter.convert(raw)
        start,end=float(item['start']),float(item['end'])
        if not 0<=start<=end<=duration+0.1:raise ValueError('invalid_speech_timestamps')
        segments.append({'start':start,'end':min(duration,end),'text':(' ' if segments else '')+text,'language':language})
        raw_parts.append(raw);languages.append(language)
    text=''.join(segment['text'] for segment in segments).strip();raw=' '.join(raw_parts)
    unique=set(languages);language=next(iter(unique)) if len(unique)==1 else ('mixed' if unique else 'unknown')
    result={'text':text,'language':language,'model':'qwen3-asr-1.7b','backend':'mlx','precision':'8bit','segments':segments,'timestamp_granularity':'chunk'}
    if converter is not None:result['text_script']='Hans'
    if text!=raw:result['raw_text']=raw
    return result
