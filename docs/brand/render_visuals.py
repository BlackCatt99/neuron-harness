"""Generate the neuron-harness visual identity, stills and motion from one scene system.

Usage: py -3 docs/brand/render_visuals.py --stills / --motion / --all
Dependencies: Pillow, NumPy; ffmpeg and ffprobe on PATH for motion.
Fonts are discovered locally, never redistributed. NH_FONT_DIR overrides the font directory.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
from pathlib import Path
import random
import shutil
import subprocess
from functools import lru_cache
from xml.sax.saxutils import escape

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
DOCS = ROOT.parent
INK = (7, 12, 17)
PAPER = (239, 242, 234)
MUTED = (155, 174, 181)
CYAN = (117, 239, 217)
LILAC = (179, 177, 247)
LINE = (42, 62, 68)
PANEL = (13, 23, 29)
SEED = 12967


def font_path(kind):
    custom = os.environ.get('NH_FONT_DIR')
    roots = [Path(custom)] if custom else []
    roots += [Path('C:/Windows/Fonts'), Path('/usr/share/fonts/truetype/dejavu'),
              Path('/usr/share/fonts/opentype/noto'), Path('/System/Library/Fonts')]
    names = {
        'regular': ['segoeui.ttf', 'DejaVuSans.ttf', 'Helvetica.ttc'],
        'light': ['segoeuil.ttf', 'DejaVuSans-ExtraLight.ttf', 'Helvetica.ttc'],
        'bold': ['segoeuib.ttf', 'DejaVuSans-Bold.ttf', 'Helvetica.ttc'],
        'mono': ['consola.ttf', 'DejaVuSansMono.ttf', 'Menlo.ttc'],
        'cn': ['msyh.ttc', 'NotoSansCJK-Regular.ttc', 'PingFang.ttc'],
        'cnlight': ['msyhl.ttc', 'NotoSansCJK-Regular.ttc', 'PingFang.ttc'],
        'cnbold': ['msyhbd.ttc', 'NotoSansCJK-Bold.ttc', 'PingFang.ttc'],
    }[kind]
    for root in roots:
        for name in names:
            candidate = root / name
            if candidate.is_file():
                return candidate
    raise RuntimeError(f'Missing font for {kind}. Set NH_FONT_DIR to installed fonts.')


@lru_cache(maxsize=150)
def ft(size, kind='regular'):
    return ImageFont.truetype(str(font_path(kind)), int(size))


def blend(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def clamp(v):
    return max(0., min(1., v))


def smooth(v):
    v = clamp(v)
    return v * v * (3 - 2 * v)


def text(draw, pos, value, size=24, color=PAPER, kind='regular', anchor='lt'):
    draw.text(pos, value, font=ft(size, kind), fill=color, anchor=anchor)


def fit(draw, pos, value, max_width, size=24, **kw):
    kind = kw.get('kind', 'regular')
    while ft(size, kind).getlength(value) > max_width and size > 14:
        size -= 1
    text(draw, pos, value, size=size, **kw)


@lru_cache(maxsize=12)
def background(w, h, focus=.74):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    x, y = xx / w, yy / h
    mint = np.exp(-(((x - focus) / .28) ** 2 + ((y - .44) / .48) ** 2) * 2.8)
    blue = np.exp(-(((x - .93) / .45) ** 2 + ((y - .90) / .4) ** 2) * 2)
    noise = np.random.default_rng(SEED).normal(0, .65, (h, w))
    arr = np.zeros((h, w, 3), np.float32)
    for i, (base, lift, cool) in enumerate(zip(INK, (4, 21, 20), (6, 6, 17))):
        arr[:, :, i] = base + mint * lift + blue * cool + noise
    return Image.fromarray(np.uint8(np.clip(arr, 0, 255)))


def mark(draw, x, y, scale=1, color=CYAN):
    pts = [(x, y), (x+17*scale, y-12*scale), (x+34*scale, y+4*scale),
           (x+17*scale, y+21*scale), (x+17*scale, y+4*scale)]
    for a, b in [(0, 1), (1, 2), (2, 3), (3, 0), (0, 4), (2, 4)]:
        draw.line([pts[a], pts[b]], fill=color, width=max(1, round(1.6*scale)))
    for px, py in pts:
        draw.ellipse((px-2.3*scale, py-2.3*scale, px+2.3*scale, py+2.3*scale), fill=color)


def brand(draw, w=1600, top=60):
    mark(draw, 72, top+14, .8)
    text(draw, (115, top), 'neuron-harness', 25, kind='bold')
    text(draw, (w-72, top+7), 'MEMORY, WITHOUT THE NOISE.', 15, MUTED, 'mono', 'rt')


def footer(draw, w, h, left='EXTERNAL MEMORY / CONTEXT ROUTING', right='OPEN SOURCE  ·  APACHE-2.0'):
    draw.line((72, h-78, w-72, h-78), fill=LINE)
    text(draw, (72, h-53), left, 16, MUTED, 'mono')
    text(draw, (w-72, h-53), right, 16, MUTED, 'mono', 'rt')


# Deterministic, sparse 3D geometry. This is a visual metaphor, not an executable graph.
def make_cloud():
    rng = random.Random(SEED)
    xyz, tiers = [], []
    for tier, count, inner, outer in [(2, 62, .20, .53), (3, 90, .55, .81), (4, 100, .83, 1.05)]:
        for _ in range(count):
            z = rng.uniform(-1, 1)
            angle = rng.uniform(0, 2*math.pi)
            r = rng.uniform(inner, outer)
            q = math.sqrt(1-z*z)
            xyz.append([r*q*math.cos(angle), r*z*.88, r*q*math.sin(angle)])
            tiers.append(tier)
    xyz = np.asarray(xyz)
    edges = set()
    for i, p in enumerate(xyz):
        distances = np.linalg.norm(xyz - p, axis=1)
        for j in np.argsort(distances)[1:4]:
            if distances[j] < .49:
                edges.add(tuple(sorted((i, int(j)))))
    return xyz, tiers, sorted(edges)


XYZ, TIERS, EDGES = make_cloud()


def neural(img, center, radius, phase=0., selected=True, opacity=1.):
    # One revolution is not implied: a tiny periodic camera motion keeps GIF loops seamless.
    angle = .35 + .10*math.sin(phase*2*math.pi)
    tilt = -.16 + .035*math.cos(phase*2*math.pi)
    rot = np.array([[math.cos(angle), 0, math.sin(angle)], [0, 1, 0],
                    [-math.sin(angle), 0, math.cos(angle)]])
    p = XYZ @ rot.T
    py = p[:, 1]*math.cos(tilt) - p[:, 2]*math.sin(tilt)
    pz = p[:, 1]*math.sin(tilt) + p[:, 2]*math.cos(tilt)
    perspective = 1 / (1 - pz*.17)
    px = center[0] + p[:, 0]*perspective*radius
    py = center[1] + py*perspective*radius
    direct = ImageDraw.Draw(img)
    glow = Image.new('RGB', img.size)
    gd = ImageDraw.Draw(glow)
    path_ids = [int(np.argmin(np.linalg.norm(XYZ-np.array(v), axis=1)))
                for v in [(.83,-.3,.25), (.48,-.1,.25), (.21,.07,.22)]]
    active_pairs = set(tuple(sorted(x)) for x in zip(path_ids, path_ids[1:]))
    for i, j in EDGES:
        depth = (pz[i]+pz[j]+2)/4
        col = blend(INK, CYAN if TIERS[i] == 2 else LILAC, (.10+.22*depth)*opacity)
        direct.line((px[i], py[i], px[j], py[j]), fill=col, width=1)
    if selected:
        route = [(px[i], py[i]) for i in path_ids] + [center]
        for a, b in zip(route, route[1:]):
            direct.line((a,b), fill=blend(INK, CYAN, .64*opacity), width=2)
            gd.line((a,b), fill=blend((0,0,0), CYAN, .21*opacity), width=4)
        u = (phase*3) % 1
        for k in range(3):
            a, b = route[k], route[k+1]
            x, y = a[0]+(b[0]-a[0])*u, a[1]+(b[1]-a[1])*u
            gd.ellipse((x-8,y-8,x+8,y+8), fill=blend((0,0,0),CYAN,.75))
            direct.ellipse((x-2,y-2,x+2,y+2), fill=PAPER)
    for i in np.argsort(pz):
        depth = (pz[i]+1.1)/2.2
        tier_fade = {2:.94, 3:.62, 4:.42}[TIERS[i]]
        c = CYAN if TIERS[i] == 2 else (LILAC if TIERS[i] == 3 else MUTED)
        bright = (.38+.62*depth)*tier_fade*opacity
        r = (1.1+depth*2.0)*(radius/420)
        if i in path_ids and selected:
            bright, r = opacity, r+1.7
            gd.ellipse((px[i]-7,py[i]-7,px[i]+7,py[i]+7), fill=blend((0,0,0),CYAN,.5))
        direct.ellipse((px[i]-r,py[i]-r,px[i]+r,py[i]+r), fill=blend(INK,c,bright))
    cx, cy = center
    rr = radius*.042
    gd.ellipse((cx-rr*2,cy-rr*2,cx+rr*2,cy+rr*2), fill=(20,115,100))
    direct.ellipse((cx-rr,cy-rr,cx+rr,cy+rr), fill=INK, outline=CYAN, width=2)
    direct.ellipse((cx-4,cy-4,cx+4,cy+4), fill=PAPER)
    from PIL import ImageChops
    img.paste(ImageChops.add(img, glow.filter(ImageFilter.GaussianBlur(max(2, radius/75)))))
    return img


def hero(lang='en', phase=.13):
    img = background(1600,900).copy()
    neural(img, (1150,440), 370, phase)
    d = ImageDraw.Draw(img)
    brand(d)
    text(d, (76,192), 'A SMALLER CONTEXT. A LONGER MEMORY.', 17, CYAN, 'mono')
    if lang == 'en':
        text(d, (70,246), 'Keep the memory.', 77, kind='light')
        text(d, (70,342), 'Lose the noise.', 77, CYAN, 'light')
        text(d, (76,484), 'External memory for long-running AI work.', 25)
        text(d, (76,528), 'Verbatim history. Task-focused context.', 25, MUTED)
    else:
        text(d, (70,249), '记忆，留在外面。', 68, kind='cnlight')
        text(d, (70,350), '专注，留给当下。', 68, CYAN, 'cnlight')
        text(d, (76,490), '为长线 AI 任务，整理每一轮上下文。', 25, kind='cn')
        text(d, (76,535), '原文留存 · 按需选取 · 有界注入', 24, MUTED, 'cn')
    d.line((76,650,126,650), fill=CYAN, width=2)
    text(d,(76,674),'PLAIN FILES.  NO SERVICE.  YOUR HARNESS.',17,MUTED,'mono')
    text(d,(1210,740),'T1  /  ACTIVE CORE',15,CYAN,'mono')
    text(d,(1210,768),'Memory metaphor',15,MUTED,'regular')
    footer(d,1600,900)
    return img


def network_frame(phase=0):
    img = background(1600,900,.57).copy()
    neural(img,(800,448),330,phase)
    d = ImageDraw.Draw(img)
    text(d,(64,52),'MEMORY / IN MOTION',18,CYAN,'mono')
    text(d,(64,95),'Recall what matters.',49,kind='light')
    text(d,(64,165),'Keep the rest intact.',25,MUTED)
    labels=[('T1','Working set + constraints',CYAN),('T2','Recent evidence / default',CYAN),
            ('T3','Long-term / explicit recall',LILAC),('T4','Lower visibility / retained',MUTED)]
    for i,(tier,label,col) in enumerate(labels):
        y=290+i*78
        d.line((66,y+7,83,y+7),fill=col,width=2)
        text(d,(99,y),tier,20,col,'mono')
        text(d,(66,y+29),label,18,MUTED)
    d.line((800,448,1020,448,1080,378,1480,378),fill=blend(INK,CYAN,.6),width=1)
    text(d,(1155,294),'SELECTED EVIDENCE',17,CYAN,'mono')
    text(d,(1155,337),'→ task pack',31,kind='light')
    text(d,(1155,425),'The main agent selects.',20)
    text(d,(1155,459),'The script assembles.',20,MUTED)
    text(d,(64,817),'SYMBOLIC MEMORY  /  NO VECTOR SEARCH',16,MUTED,'mono')
    text(d,(1536,817),'Memory metaphor · not a runtime graph',16,MUTED,'regular','rt')
    return img


STEPS = [
    ('01', 'Initialize', 'Init', 'Create a project-local memory store.'),
    ('02', 'Record', 'LogRaw', 'Append the original message to raw.log.'),
    ('03', 'Archive + select', 'Archive', 'The main agent classifies and selects evidence.'),
    ('04', 'Assemble', 'Assemble', 'Render a bounded task pack for a subagent.'),
]
COMMANDS = [
    'pwsh -File scripts/assemble.ps1 -Mode Init -Project ./demo',
    'pwsh -File scripts/assemble.ps1 -Mode LogRaw -TaskId demo',
    'pwsh -File scripts/assemble.ps1 -Mode Archive -Type evidence',
    'pwsh -File scripts/assemble.ps1 -Mode Assemble -TaskId demo',
]


def quick_frame(seconds=0):
    img=background(1600,900,.8).copy()
    d=ImageDraw.Draw(img)
    text(d,(64,48),'FROM HISTORY TO A CLEAN HANDOFF',17,CYAN,'mono')
    text(d,(60,91),'Your harness. A focused context.',51,kind='light')
    text(d,(64,164),'PowerShell 7  /  plain files  /  no background service',22,MUTED)
    current=min(3,int(seconds/2.5))
    local=(seconds%2.5)/2.5
    for i,(num,title,_,note) in enumerate(STEPS):
        y=268+i*116
        is_on=i==current
        col=CYAN if is_on else (PAPER if i<current else MUTED)
        d.line((66,y,66,y+63), fill=col if is_on else LINE,width=3)
        text(d,(91,y),num,18,col,'mono')
        text(d,(140,y-5),title,29,col,'regular')
        text(d,(140,y+40),note,18,MUTED)
    # The terminal is a clearly labelled illustration, not a fabricated app screenshot.
    x,y,w,h=786,265,744,437
    d.rounded_rectangle((x,y,x+w,y+h),radius=16,fill=PANEL,outline=LINE)
    for i,col in enumerate([(91,112,119),(91,112,119),(91,112,119)]):
        d.ellipse((x+25+i*19,y+25,x+32+i*19,y+32),fill=col)
    text(d,(x+108,y+22),'COMMAND WALKTHROUGH',15,MUTED,'mono')
    d.line((x,y+62,x+w,y+62),fill=LINE)
    text(d,(x+30,y+94),'~/neuron-harness',18,MUTED,'mono')
    cmd=COMMANDS[current]
    # Wrap exactly at argument boundaries for small README render sizes.
    pieces=cmd.split(' -Mode ')
    lines=['$ '+pieces[0], '  -Mode '+pieces[1]]
    allchars=sum(map(len,lines))
    reveal=int(allchars*smooth(min(1,local/.28)))
    remaining=reveal
    for i,line in enumerate(lines):
        shown=line[:max(0,remaining)]
        text(d,(x+30,y+143+i*39),shown,22,CYAN,'mono')
        remaining-=len(line)
    if local>.30:
        text(d,(x+30,y+252),'→ '+STEPS[current][1],25,kind='regular')
        text(d,(x+30,y+299),'Arguments abbreviated. Full example in README.',16,MUTED)
        if current==2:
            text(d,(x+30,y+333),'Selection is a model decision, not automatic.',16,LILAC)
        else:
            text(d,(x+30,y+333),'Illustration · not a speed benchmark',16,MUTED)
    footer(d,1600,900,'INIT → LOGRAW → ARCHIVE + SELECT → ASSEMBLE','NOT ONE-STEP AUTOMATION')
    return img


class Diagram:
    def __init__(self,w,h):
        self.w,self.h=w,h
        self.image=background(w,h,.45).copy()
        self.d=ImageDraw.Draw(self.image)
        self.parts=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="neuron-harness architecture">',
                    '<title>neuron-harness architecture</title>',
                    '<desc>The main agent makes semantic choices. A deterministic script records originals, stores tiered evidence, assembles a bounded task pack and validates staging before approval. Short-lived subagents receive only the task pack.</desc>',
                    '<rect width="100%" height="100%" fill="#070c11"/>']

    @staticmethod
    def color(c):
        return '#%02x%02x%02x'%c

    def txt(self,x,y,s,size=24,col=PAPER,kind='regular'):
        text(self.d,(x,y),s,size,col,kind)
        family='Microsoft YaHei, Noto Sans CJK SC, sans-serif' if kind.startswith('cn') else ('Consolas, monospace' if kind=='mono' else 'Segoe UI, sans-serif')
        self.parts.append(f'<text x="{x}" y="{y+size*.82}" font-family="{family}" font-size="{size}" fill="{self.color(col)}">{escape(s)}</text>')

    def line(self,pts,col=LINE,width=1,arrow=False):
        self.d.line(pts,fill=col,width=width)
        points=' '.join(f'{x},{y}' for x,y in pts)
        self.parts.append(f'<polyline points="{points}" fill="none" stroke="{self.color(col)}" stroke-width="{width}"/>')
        if arrow:
            x,y=pts[-1]; ax,ay=pts[-2]
            theta=math.atan2(y-ay,x-ax)
            a=(x-9*math.cos(theta-.5),y-9*math.sin(theta-.5))
            b=(x-9*math.cos(theta+.5),y-9*math.sin(theta+.5))
            self.d.polygon([(x,y),a,b],fill=col)
            self.parts.append(f'<polygon points="{x},{y} {a[0]},{a[1]} {b[0]},{b[1]}" fill="{self.color(col)}"/>')

    def box(self,x,y,w,h,col=PANEL,stroke=LINE):
        self.d.rounded_rectangle((x,y,x+w,y+h),radius=14,fill=col,outline=stroke)
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{self.color(col)}" stroke="{self.color(stroke)}"/>')

    def save(self,path):
        Path(str(path)+'.png').write_bytes(self.png_bytes())
        Path(str(path)+'.svg').write_text('\n'.join(self.parts+['</svg>']),encoding='utf-8')

    def png_bytes(self):
        out = io.BytesIO()
        self.image.save(out, format='PNG')
        return out.getvalue()


def architecture(lang='en'):
    a=Diagram(1600,1100)
    cn=lang=='zh'; k='cn' if cn else 'regular'
    a.txt(64,48,'THE SYSTEM / NOT THE METAPHOR',17,CYAN,'mono')
    a.txt(60,92,'保留历史，整理上下文。' if cn else 'Keep the history. Curate the context.',48,kind='cnlight' if cn else 'light')
    a.txt(64,165,'模型做语义判断，脚本兑现硬规则。' if cn else 'The model makes semantic choices. The script enforces hard rules.',24,MUTED,k)
    # Message recording is separate from archive selection.
    a.box(64,244,296,134)
    a.txt(88,266,'01 / INPUT',16,MUTED,'mono')
    a.txt(88,302,'用户消息' if cn else 'Session messages',27,kind=k)
    a.txt(88,342,'原文只追加 → raw.log' if cn else 'Append originals → raw.log',19,CYAN,k)
    a.box(64,425,296,310)
    a.txt(88,448,'02 / MAIN AGENT',16,MUTED,'mono')
    a.txt(88,493,'语义判断' if cn else 'Semantic choices',28,kind=k)
    for j,s in enumerate(['归档分类','维护工作集','选取相关证据'] if cn else ['Classify & archive','Maintain working set','Select relevant evidence']):
        a.txt(88,550+j*47,s,21,PAPER,k)
    a.line([(212,378),(212,417)],CYAN,2,True)
    a.line([(360,538),(410,538)],CYAN,2,True)
    a.box(420,244,560,491)
    a.txt(444,266,'03 / PERSISTENT MEMORY',16,MUTED,'mono')
    a.txt(444,303,'.neuron-harness/',29,kind='mono')
    tiers=[('T1','工作集 + 活跃约束','每轮注入','Working set + constraints','Injected every turn',CYAN),
           ('T2','近期证据','Search 默认层','Recent evidence','Default Search tier',CYAN),
           ('T3','长期证据 / 决策','显式扩层召回','Long-term / decisions','Explicit tier expansion',LILAC),
           ('T4','功能性遗忘','降低可见性，原文保留','Functional forgetting','Lower visibility; originals retained',MUTED)]
    for i,(tier,zh,zn,en,enn,col) in enumerate(tiers):
        y=370+i*83
        a.line([(448,y+2),(448,y+57)],col,3)
        a.txt(466,y,tier,23,col,'mono')
        a.txt(524,y,zh if cn else en,23,PAPER,k)
        a.txt(524,y+36,zn if cn else enn,18,MUTED,k)
    a.line([(980,505),(1012,505),(1012,375),(1036,375)],CYAN,2,True)
    a.box(1044,244,492,227)
    a.txt(1068,266,'04 / DETERMINISTIC SCRIPT',16,MUTED,'mono')
    a.txt(1068,307,'预算内任务包' if cn else 'Bounded task pack',30,kind=k)
    a.txt(1068,365,'规则 + 工作集 + 选中证据 + 指令' if cn else 'Rules + working set + evidence',21,PAPER,k)
    a.txt(1068,407,'预算 / 格式 / 来源存在性 / 原子写' if cn else 'Budget / format / sources / atomic writes',20,MUTED,k)
    a.line([(1288,471),(1288,530)],CYAN,2,True)
    a.box(1044,542,492,193)
    a.txt(1068,564,'05 / SUBAGENT',16,MUTED,'mono')
    a.txt(1068,606,'短生命周期子代理' if cn else 'Short-lived subagent',30,kind=k)
    a.txt(1068,664,'只收任务包，不继承主会话' if cn else 'Task pack only. No inherited session.',21,MUTED,k)
    # A visible review gate returns to storage, never to a particular tier.
    a.line([(1288,735),(1288,797)],LILAC,2,True)
    a.box(420,808,1116,115)
    a.txt(444,830,'06 / STAGING',16,LILAC,'mono')
    a.txt(660,829,'来源存在性校验 + 语义复核 → 批准 / 拒绝' if cn else 'Source checks + semantic review → approve / reject',24,PAPER,k)
    a.txt(660,872,'获批产物回写存储；来源存在不等于语义正确。' if cn else 'Approved output returns to storage; source existence is not proof of correctness.',18,MUTED,k)
    a.line([(420,865),(390,865),(390,709),(412,709)],LILAC,2,True)
    a.txt(64,968,'T1 不是归档目录。T4 discard 不参与 Search，已知 ID 可 Fetch。' if cn else 'T1 is not an archive tier. T4 discard entries are hidden from Search; Fetch accepts known IDs.',19,MUTED,k)
    a.txt(64,1010,'符号化文件记忆 · 无向量检索 · 非自动图遍历' if cn else 'Symbolic file-backed memory · no vector search · no automatic graph traversal',18,CYAN,k)
    a.save(DOCS/('architecture' if cn else 'architecture.en'))


def social():
    img=background(1280,640).copy()
    neural(img,(1010,310),255,.17)
    d=ImageDraw.Draw(img)
    mark(d,64,66,.8)
    text(d,(106,53),'neuron-harness',23,kind='bold')
    text(d,(60,173),'Keep the memory.',65,kind='light')
    text(d,(60,252),'Lose the noise.',65,CYAN,'light')
    text(d,(64,371),'External memory for long-running AI work.',23)
    text(d,(64,416),'Verbatim history. Task-focused context.',22,MUTED)
    d.line((64,516,1216,516),fill=LINE)
    text(d,(64,552),'HARNESS-AGNOSTIC  /  APACHE-2.0',17,MUTED,'mono')
    text(d,(1216,552),'MEMORY METAPHOR',14,MUTED,'mono','rt')
    img.save(ROOT/'social-preview.png')


def poster():
    img=background(1080,1440,.55).copy()
    neural(img,(540,803),405,.17)
    d=ImageDraw.Draw(img)
    mark(d,64,73,.8)
    text(d,(106,60),'neuron-harness',25,kind='bold')
    text(d,(64,173),'给长线 AI 任务',25,MUTED,'cn')
    text(d,(57,243),'一个有记忆的',78,kind='cnlight')
    text(d,(57,352),'干净上下文。',78,CYAN,'cnlight')
    text(d,(64,484),'原文留存 · 按需选取 · 有界注入',28,MUTED,'cn')
    text(d,(540,1181),'记忆组织示意 · 非神经网络模型',19,MUTED,'cn','mt')
    d.line((64,1250,1016,1250),fill=LINE)
    text(d,(64,1290),'开源 / Apache-2.0',24,kind='cn')
    text(d,(64,1340),'github.com/BlackCatt99/neuron-harness-skill',23,CYAN,'mono')
    img.save(ROOT/'poster.zh.png')


def logo():
    img=background(512,512,.5).copy()
    d=ImageDraw.Draw(img)
    mark(d,120,230,8,CYAN)
    img.save(ROOT/'logo.png')
    # Original geometric brand mark, not a third-party icon.
    (ROOT/'logo.svg').write_text('''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="neuron-harness mark"><rect width="128" height="128" rx="28" fill="#070c11"/><g fill="none" stroke="#75efd9" stroke-width="2"><path d="M30 58L64 34L98 66L64 100Z M30 58L64 66L98 66"/></g><g fill="#75efd9"><circle cx="30" cy="58" r="4"/><circle cx="64" cy="34" r="4"/><circle cx="98" cy="66" r="4"/><circle cx="64" cy="100" r="4"/><circle cx="64" cy="66" r="4"/></g></svg>''',encoding='utf-8')


def stills():
    ROOT.mkdir(parents=True,exist_ok=True)
    for lang in ['zh','en']:
        hero(lang).save(ROOT/f'hero.{lang}.png')
        architecture(lang)
    network_frame(.17).save(ROOT/'memory-network.png')
    quick_frame(8.7).save(ROOT/'quickstart.png')
    social(); poster(); logo()
    print('Static visual system rendered.',flush=True)


def pipe_video(path, frame_fn, duration, fps=30, size=(1920,1080)):
    command=['ffmpeg','-hide_banner','-loglevel','error','-y','-f','rawvideo','-pixel_format','rgb24',
             '-video_size',f'{size[0]}x{size[1]}','-framerate',str(fps),'-i','-',
             '-an','-c:v','libx264','-preset','fast','-crf','19','-pix_fmt','yuv420p','-movflags','+faststart',str(path)]
    proc=subprocess.Popen(command,stdin=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        for i in range(round(duration*fps)):
            im=frame_fn(i/fps).resize(size,Image.Resampling.LANCZOS)
            proc.stdin.write(im.tobytes())
            if i%(fps*3)==0:
                print(f'{path.name}: {i/fps:.0f}/{duration:.0f}s',flush=True)
        proc.stdin.close()
        error=proc.stderr.read().decode('utf-8',errors='replace')
        result=proc.wait(timeout=120)
        if result:
            raise RuntimeError(error)
    finally:
        if proc.poll() is None:
            proc.kill()


def gif(path,frames,duration=100):
    # A single sampled global palette prevents per-frame palette flicker.
    thumb=[im.resize((160,90)) for im in frames[::max(1,len(frames)//12)]]
    atlas=Image.new('RGB',(160,len(thumb)*90))
    for i,im in enumerate(thumb): atlas.paste(im,(0,i*90))
    palette=atlas.quantize(colors=192,method=Image.Quantize.MEDIANCUT)
    indexed=[im.quantize(palette=palette,dither=Image.Dither.NONE) for im in frames]
    indexed[0].save(path,save_all=True,append_images=indexed[1:],duration=duration,loop=0,optimize=True,disposal=1)
    mb=path.stat().st_size/1024**2
    print(f'{path.name}: {mb:.2f} MiB',flush=True)
    if mb>8:
        raise RuntimeError(f'{path.name} exceeds the 8 MiB animation budget')


def promo_frame(t):
    if t<4:
        return hero('zh',t/10)
    if t<10:
        im=network_frame((t-4)/6)
        return im
    if t<20:
        return quick_frame(t-10)
    im=hero('zh',(t-20)/10)
    d=ImageDraw.Draw(im)
    d.rectangle((70,640,775,732),fill=INK)
    text(d,(76,659),'github.com/BlackCatt99/',23,CYAN,'mono')
    text(d,(76,696),'neuron-harness-skill',23,CYAN,'mono')
    return im


def motion():
    # First frame is useful even if animation is disabled or not loaded.
    gif(ROOT/'memory-network.gif',[network_frame(i/60).resize((960,540),Image.Resampling.LANCZOS) for i in range(60)],100)
    gif(ROOT/'quickstart.gif',[quick_frame(i/8).resize((1120,630),Image.Resampling.LANCZOS) for i in range(80)],125)
    target=ROOT/'neuron-harness-film.mp4'
    pipe_video(target,promo_frame,24)
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(target)],text=True))
    probe['format']['filename']=target.name
    (ROOT/'media-info.json').write_text(json.dumps(probe,indent=2),encoding='utf-8')
    print('Motion exports complete.',flush=True)


def contact_sheets():
    # Motion is inspected separately from the independent static visual gate.
    sheet=Image.new('RGB',(1600,4*450),INK)
    for i,t in enumerate([1,4.5,8,10.5,13.5,16.5,19.5,22]):
        out=subprocess.check_output(['ffmpeg','-v','error','-ss',str(t),'-i',str(ROOT/'neuron-harness-film.mp4'),'-frames:v','1','-f','image2pipe','-vcodec','png','-'])
        im=Image.open(io.BytesIO(out)).convert('RGB').resize((800,450))
        sheet.paste(im,((i%2)*800,(i//2)*450))
    sheet.save(ROOT/'motion-contact-sheet.jpg',quality=92)


def checks():
    from xml.etree import ElementTree
    for p in [DOCS/'architecture.svg',DOCS/'architecture.en.svg',ROOT/'logo.svg']:
        ElementTree.parse(p)
    expected={'hero.zh.png':(1600,900),'hero.en.png':(1600,900),'social-preview.png':(1280,640),
              'poster.zh.png':(1080,1440),'logo.png':(512,512),'memory-network.png':(1600,900),
              'quickstart.png':(1600,900)}
    for name,size in expected.items():
        with Image.open(ROOT/name) as im:
            assert im.size==size,(name,im.size)
            im.verify()
    sizes={p.name:p.stat().st_size for p in ROOT.iterdir() if p.suffix in ['.png','.gif','.mp4','.svg']}
    (ROOT/'asset-manifest.json').write_text(json.dumps({'seed':SEED,'files':sizes},indent=2),encoding='utf-8')
    print('Dimensions, SVG XML and decode checks passed.',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--stills',action='store_true')
    parser.add_argument('--motion',action='store_true')
    parser.add_argument('--all',action='store_true')
    parser.add_argument('--contact-sheet',action='store_true')
    opts=parser.parse_args()
    if opts.stills or opts.all: stills()
    if opts.motion or opts.all: motion()
    if opts.contact_sheet: contact_sheets()
    checks()
