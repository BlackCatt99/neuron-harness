"""Deterministic asset and text-boundary checks; not an aesthetic/visual acceptance pass."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('visuals',ROOT/'render_visuals.py')
v=importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
issues=[]
scene=''
real_text=v.text

def checked_text(draw,pos,value,size=24,color=v.PAPER,kind='regular',anchor='lt'):
    box=draw.textbbox(pos,value,font=v.ft(size,kind),anchor=anchor)
    w,h=draw._image.size
    if box[0]<0 or box[1]<0 or box[2]>w or box[3]>h:
        issues.append({'scene':scene,'text':value,'bounds':box,'canvas':[w,h]})
    return real_text(draw,pos,value,size,color,kind,anchor)

v.text=checked_text
for lang in ['zh','en']:
    scene='hero.'+lang;v.hero(lang)
    scene='architecture.'+lang;v.architecture(lang)
scene='social';v.social()
scene='poster';v.poster()
scene='network';v.network_frame(.17)
for t in [0,.8,2.6,3.3,5.8,8.6,9.7]:
    scene='quickstart.'+str(t);v.quick_frame(t)

assert not issues,json.dumps(issues,ensure_ascii=False,indent=2)

motion={}
for name,minimum in [('memory-network.gif',50),('quickstart.gif',20)]:
    path=ROOT/name
    with Image.open(path) as im:
        assert im.n_frames>=minimum
        frame_count=im.n_frames
        elapsed=0
        for frame_index in range(frame_count):
            im.seek(frame_index)
            elapsed+=im.info.get('duration',0)
        assert abs(elapsed-({'memory-network.gif':6000,'quickstart.gif':9600}[name]))<500
        im.seek(0);first=im.convert('RGB').copy()
        im.seek(frame_count//2);later=im.convert('RGB').copy()
        assert ImageChops.difference(first,later).getbbox() is not None
        motion[name]={'frames':im.n_frames,'bytes':path.stat().st_size,'changing':True}
assert sum(x['bytes'] for x in motion.values())<10*1024**2
film=ROOT/'neuron-harness-film.mp4'
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(film)],text=True))
stream=next(x for x in probe['streams'] if x['codec_type']=='video')
assert (stream['width'],stream['height'])==(1920,1080)
assert stream['r_frame_rate']=='30/1'
assert abs(float(probe['format']['duration'])-24)<.05
subprocess.run(['ffmpeg','-v','error','-i',str(film),'-f','null','-'],check=True,capture_output=True)
black=subprocess.run(['ffmpeg','-hide_banner','-i',str(film),'-vf','blackdetect=d=0.15:pix_th=0.05:pic_th=0.999','-an','-f','null','-'],check=True,capture_output=True,text=True)
assert 'black_start:' not in black.stderr
links=[]
for name in ['README.md','README.en.md']:
    content=(ROOT.parent.parent/name).read_text(encoding='utf-8')
    for link in re.findall(r'\]\(([^)]+)\)',content):
        if '://' in link or link.startswith('#'):continue
        path=ROOT.parent.parent/link.split('#')[0]
        assert path.exists(),(name,link)
        links.append(link)
result={'technical_checks':'pass','text_canvas_overflow':issues,'gif_checks':motion,
        'video':{'duration':24,'width':1920,'height':1080,'fps':30,'decode':'pass','black_gaps':'none detected','audio':'intentionally silent'},
        'readme_links_checked':len(links),
        'visual_acceptance':'blocked: visual-judge provider unavailable; current model image input unavailable; no aesthetic approval claimed'}
(ROOT/'qa-report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
