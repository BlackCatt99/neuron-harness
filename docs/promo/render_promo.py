# -*- coding: utf-8 -*-
"""
neuron-harness 宣传片渲染器
逐帧用 Pillow 绘制，ffmpeg 合成 MP4。

设计：把 T1-T4 分层记忆画成一张会呼吸的网络图——
中心是工作集（神经元胞体），向外逐层扩散，条目按访问新鲜度明暗起伏，
旧条目下沉变暗但不消失（体现"原文永不删除"）。
"""
import math
import os
import random
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
FPS = 30
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'frames')
VIDEO = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'neuron-harness-promo.mp4')

# 配色（与架构图一致）
BG = (13, 17, 23)
PANEL = (22, 27, 34)
EDGE = (48, 54, 61)
WHITE = (230, 237, 243)
GREY = (139, 148, 158)
DIM = (110, 118, 129)
T1 = (86, 211, 100)   # 绿
T2 = (121, 192, 255)  # 蓝
T3 = (210, 168, 255)  # 紫
T4 = (173, 186, 199)  # 灰

CN_FONT = r'C:\Windows\Fonts\msyh.ttc'
CN_BOLD = r'C:\Windows\Fonts\msyhbd.ttc'
MONO = r'C:\Windows\Fonts\consola.ttf'


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


F_TITLE = font(CN_BOLD, 74)
F_SUB = font(MONO, 30)
F_H2 = font(CN_BOLD, 46)
F_BODY = font(CN_FONT, 34)
F_SMALL = font(CN_FONT, 26)
F_TINY = font(MONO, 21)
F_NOTE = font(CN_FONT, 21)   # 中文备注：MONO 不含中文字形，会渲染成豆腐块
F_LABEL = font(MONO, 24)


def center_text(draw, xy, text, f, fill, anchor='mm'):
    draw.text(xy, text, font=f, fill=fill, anchor=anchor)


# ---------- 场景 1：开场标题 ----------
def scene_title(t):
    """t: 0..1"""
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    # 背景噪点网格（淡）
    for x in range(0, W, 120):
        d.line([(x, 0), (x, H)], fill=(20, 25, 31), width=1)
    for y in range(0, H, 120):
        d.line([(0, y), (W, y)], fill=(20, 25, 31), width=1)

    ease = 1 - (1 - min(t * 1.6, 1)) ** 3

    # 中心发散光晕
    glow = Image.new('RGB', (W, H), BG)
    gd = ImageDraw.Draw(glow)
    r = int(120 + 260 * ease)
    gd.ellipse([W // 2 - r, H // 2 - r - 90, W // 2 + r, H // 2 + r - 90],
               fill=(22, 40, 30))
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    img = Image.blend(img, glow, 0.85)
    d = ImageDraw.Draw(img)

    # 神经元胞体
    cx, cy = W // 2, H // 2 - 90
    for ring, (rad, col) in enumerate([
        (26 + 6 * math.sin(t * 6), T1),
        (44 + 4 * math.sin(t * 5 + 1), (40, 90, 55)),
    ]):
        d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], outline=col, width=2)
    d.ellipse([cx - 12, cy - 12, cx + 12, cy + 12], fill=T1)

    # 放射枝突
    random.seed(7)
    for i in range(10):
        ang = i * (2 * math.pi / 10) + t * 0.9
        ln = 70 + 40 * ease
        x2 = cx + math.cos(ang) * ln
        y2 = cy + math.sin(ang) * ln
        mx = cx + math.cos(ang + 0.4) * ln * 0.6
        my = cy + math.sin(ang + 0.4) * ln * 0.6
        d.line([(cx, cy), (mx, my), (x2, y2)], fill=(45, 80, 55), width=2)
        d.ellipse([x2 - 3, y2 - 3, x2 + 3, y2 + 3], fill=(70, 130, 90))

    # 标题
    alpha_t = max(0.0, (t - 0.18) / 0.5)
    if alpha_t > 0:
        a = min(alpha_t, 1.0)
        col = tuple(int(BG[i] + (WHITE[i] - BG[i]) * a) for i in range(3))
        center_text(d, (W // 2, cy + 190), 'neuron-harness', F_TITLE, col)
        sub = tuple(int(BG[i] + (GREY[i] - BG[i]) * a) for i in range(3))
        center_text(d, (W // 2, cy + 275), 'EXTERNAL MEMORY  ·  CONTEXT ROUTING',
                    F_SUB, sub)

    # 副标题（更晚出现）
    if t > 0.55:
        a2 = min((t - 0.55) / 0.35, 1.0)
        col2 = tuple(int(BG[i] + (DIM[i] - BG[i]) * a2) for i in range(3))
        center_text(d, (W // 2, cy + 340), '给长线会话一个不会遗忘的大脑', F_BODY, col2)
    return img


# ---------- 场景 2：记忆分层网络 ----------
def make_nodes():
    """固定随机种子，保证每帧位置一致。"""
    rnd = random.Random(20261029)
    nodes = []
    # T1 核心
    nodes.append({'x': W / 2, 'y': H / 2, 'tier': 1, 'label': 'T1', 'core': True})
    # 各层环上的节点
    specs = [(2, 240, 9), (3, 370, 12), (4, 490, 15)]
    for tier, radius, count in specs:
        for i in range(count):
            ang = (2 * math.pi / count) * i + rnd.uniform(-0.09, 0.09)
            rr = radius + rnd.uniform(-26, 26)
            nodes.append({
                'x': W / 2 + math.cos(ang) * rr * 1.30,
                'y': H / 2 + math.sin(ang) * rr * 0.72,
                'tier': tier,
                'phase': rnd.uniform(0, 2 * math.pi),
                'label': '',
            })
    return nodes


NODES = make_nodes()
TIER_COL = {1: T1, 2: T2, 3: T3, 4: T4}


def scene_network(t):
    """t: 0..1 全场景进度"""
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    # 相机缓慢推近 + 轻微上移
    zoom = 1.02 + 0.06 * t
    cx0, cy0 = W / 2, H / 2

    def proj(x, y):
        return (cx0 + (x - cx0) * zoom, cy0 + (y - cy0) * zoom)

    # 连线：核心到各层，按距离逐渐变暗
    core = NODES[0]
    cpx, cpy = proj(core['x'], core['y'])
    for n in NODES[1:]:
        px, py = proj(n['x'], n['y'])
        base = TIER_COL[n['tier']]
        # 层级越外越暗
        fade = {2: 1.0, 3: 0.62, 4: 0.34}[n['tier']]
        # 呼吸：沿半径方向的信号脉冲
        pulse = 0.5 + 0.5 * math.sin(t * 9 - n['tier'] * 1.4 + n.get('phase', 0))
        k = fade * (0.28 + 0.42 * pulse)
        col = tuple(int(BG[i] + (base[i] - BG[i]) * k) for i in range(3))
        d.line([(cpx, cpy), (px, py)], fill=col, width=1)

    # 邻接边（同层相邻节点间，模拟网络）
    for i in range(1, len(NODES)):
        for j in range(i + 1, len(NODES)):
            a, b = NODES[i], NODES[j]
            if a['tier'] != b['tier']:
                continue
            dist = math.hypot(a['x'] - b['x'], a['y'] - b['y'])
            if dist > 210:
                continue
            ax, ay = proj(a['x'], a['y'])
            bx, by = proj(b['x'], b['y'])
            d.line([(ax, ay), (bx, by)], fill=(26, 32, 40), width=1)

    # 节点
    for n in NODES:
        px, py = proj(n['x'], n['y'])
        base = TIER_COL[n['tier']]
        if n.get('core'):
            rr = 30 + 4 * math.sin(t * 18)
            d.ellipse([px - rr, py - rr, px + rr, py + rr], fill=(20, 42, 28))
            d.ellipse([px - rr, py - rr, px + rr, py + rr], outline=T1, width=3)
            d.ellipse([px - 11, py - 11, px + 11, py + 11], fill=T1)
            center_text(d, (px, py + rr + 34), 'WORKING SET', F_LABEL, T1)
            continue

        # 新鲜度脉动：外圈越慢越弱
        sp = {2: 0.9, 3: 0.62, 4: 0.38}[n['tier']]
        ph = n.get('phase', 0)
        bright = 0.55 + 0.45 * math.sin(t * 16 * sp + ph)
        rr = {2: 7, 3: 6, 4: 5}[n['tier']] + bright * 2.2
        k = {2: 0.95, 3: 0.70, 4: 0.42}[n['tier']] * (0.62 + 0.38 * bright)
        col = tuple(int(BG[i] + (base[i] - BG[i]) * k) for i in range(3))
        d.ellipse([px - rr, py - rr, px + rr, py + rr], fill=col)
        # 外发光
        if n['tier'] == 2:
            d.ellipse([px - rr - 6, py - rr - 6, px + rr + 6, py + rr + 6],
                      outline=tuple(int(c * 0.4) for c in base), width=1)

    # 层标签（左侧图例，淡入）
    if t > 0.12:
        a = min((t - 0.12) / 0.2, 1.0)
        labels = [
            ('T1  工作集', T1, '每轮强制注入'),
            ('T2  近期证据', T2, '默认检索面'),
            ('T3  长期 / 决策', T3, '需显式扩层'),
            ('T4  功能性遗忘', T4, '原文永不删除'),
        ]
        y0 = 120
        for i, (name, col, note) in enumerate(labels):
            yy = y0 + i * 66
            cc = tuple(int(BG[j] + (col[j] - BG[j]) * a) for j in range(3))
            nn = tuple(int(BG[j] + (DIM[j] - BG[j]) * a) for j in range(3))
            d.ellipse([80, yy - 6, 92, yy + 6], fill=cc)
            d.text((108, yy), name, font=F_SMALL, fill=cc, anchor='lm')
            d.text((330, yy), note, font=F_NOTE, fill=nn, anchor='lm')
    return img


# ---------- 场景 3：任务包组装 ----------
def scene_pack(t):
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    # 左侧：全部历史条（很多，暗）
    d.text((110, 90), 'raw.log  ·  全部历史', font=F_SMALL, fill=GREY, anchor='lm')
    rnd = random.Random(99)
    hist = []
    for i in range(26):
        x = 110 + rnd.uniform(0, 300)
        y = 150 + i * 32
        w = rnd.uniform(90, 250)
        hist.append((x, y, w))

    appear = min(t / 0.35, 1.0)
    for i, (x, y, w) in enumerate(hist):
        if i / len(hist) > appear:
            break
        d.rounded_rectangle([x, y, x + w, y + 16], radius=4, fill=(30, 36, 44))

    # 中间：筛选箭头
    if t > 0.3:
        a = min((t - 0.3) / 0.2, 1.0)
        ax = 520
        for i in range(3):
            yy = 420 + i * 40
            col = tuple(int(BG[j] + (T2[j] - BG[j]) * a) for j in range(3))
            d.line([(ax, yy), (ax + 90, yy)], fill=col, width=3)
            d.polygon([(ax + 90, yy), (ax + 78, yy - 6), (ax + 78, yy + 6)], fill=col)
        cc = tuple(int(BG[j] + (GREY[j] - BG[j]) * a) for j in range(3))
        d.text((ax + 45, 300), '选取', font=F_SMALL, fill=cc, anchor='mm')

    # 右侧：任务包（少量，亮）
    if t > 0.45:
        a = min((t - 0.45) / 0.3, 1.0)
        bx, by = 760, 170
        bw, bh = 1010, 700
        panel = Image.new('RGB', (int(bw), int(bh)), BG)
        pd = ImageDraw.Draw(panel)
        pd.rounded_rectangle([0, 0, bw - 1, bh - 1], radius=14,
                             fill=(19, 24, 31), outline=(45, 52, 61), width=1)
        rows = [
            ('系统规则', T1), ('硬约束（全局+本线）', T1), ('工作集', T1),
            ('相关证据 E0001  tier=t2', T2), ('相关证据 E0004  tier=t3', T3),
            ('近期对话', GREY), ('本次指令', (255, 210, 120)),
            ('反问协议', DIM),
        ]
        for i, (name, col) in enumerate(rows):
            yy = 34 + i * 78
            if i / len(rows) > a:
                break
            pd.rounded_rectangle([26, yy, bw - 26, yy + 56], radius=8,
                                 fill=(24, 30, 38), outline=tuple(int(c * 0.35) for c in col), width=1)
            pd.ellipse([48, yy + 22, 60, yy + 34], fill=col)
            pd.text((78, yy + 28), name, font=F_SMALL, fill=WHITE, anchor='lm')

        # 淡入
        panel = panel.convert('RGB')
        img.paste(panel, (bx, by)) if a >= 1 else img.paste(
            Image.blend(Image.new('RGB', panel.size, BG), panel, a), (bx, by))

        cc = tuple(int(BG[j] + (GREY[j] - BG[j]) * a) for j in range(3))
        d.text((bx + bw // 2, by + bh + 40), '预算内 · 只带本轮需要的', font=F_SMALL, fill=cc, anchor='mm')
    return img


# ---------- 场景 4：结尾 ----------
def scene_end(t):
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    for x in range(0, W, 120):
        d.line([(x, 0), (x, H)], fill=(17, 21, 27), width=1)
    for y in range(0, H, 120):
        d.line([(0, y), (W, y)], fill=(17, 21, 27), width=1)

    a = min(t / 0.4, 1.0)
    cy = H // 2 - 120
    # 收缩的神经元
    r = 90 * (1 - 0.55 * a)
    for ring, rad in [(1, r), (2, r * 1.6), (3, r * 2.3)]:
        col = tuple(int(BG[j] + (T1[j] * (0.8 / ring) - BG[j] * 0) * a) for j in range(3))
        col = tuple(min(255, int(c)) for c in col)
        if ring == 1:
            d.ellipse([W // 2 - rad, cy - rad, W // 2 + rad, cy + rad], outline=T1, width=3)
        else:
            d.ellipse([W // 2 - rad, cy - rad, W // 2 + rad, cy + rad],
                      outline=(35, 55, 42), width=1)
    d.ellipse([W // 2 - 10, cy - 10, W // 2 + 10, cy + 10], fill=T1)

    lines = [
        ('原文永不删除', F_H2, WHITE, cy + 230),
        ('遗忘只改变到达成本，永不改变可达性', F_BODY, GREY, cy + 300),
    ]
    if t > 0.25:
        a2 = min((t - 0.25) / 0.3, 1.0)
        for text, f, col, yy in lines:
            cc = tuple(int(BG[j] + (col[j] - BG[j]) * a2) for j in range(3))
            center_text(d, (W // 2, yy), text, f, cc)

    if t > 0.55:
        a3 = min((t - 0.55) / 0.3, 1.0)
        cc = tuple(int(BG[j] + (T2[j] - BG[j]) * a3) for j in range(3))
        center_text(d, (W // 2, H - 160), 'github.com/BlackCatt99/neuron-harness',
                    font(MONO, 34), cc)
        cc2 = tuple(int(BG[j] + (DIM[j] - BG[j]) * a3) for j in range(3))
        center_text(d, (W // 2, H - 105), 'Apache-2.0  ·  PowerShell 7+  ·  28 integration tests',
                    F_TINY, cc2)
    return img


# ---------- 时间轴 ----------
def ease_io(x):
    return 0.5 - 0.5 * math.cos(math.pi * max(0.0, min(1.0, x)))


SCENES = [
    (scene_title, 3.2),
    (scene_network, 8.0),
    (scene_pack, 6.0),
    (scene_end, 4.2),
]


def render():
    os.makedirs(OUT_DIR, exist_ok=True)
    # 清理旧帧
    for f in os.listdir(OUT_DIR):
        if f.endswith('.png'):
            os.remove(os.path.join(OUT_DIR, f))

    total = sum(d for _, d in SCENES)
    frames = int(total * FPS)
    print(f'总时长 {total:.1f}s, {frames} 帧 @ {FPS}fps')

    idx = 0
    for scene_fn, dur in SCENES:
        n = int(dur * FPS)
        for i in range(n):
            t = i / max(n - 1, 1)
            # 场景间淡入淡出（首尾 0.3s）
            img = scene_fn(t)
            fade = 1.0
            edge = 0.32
            secs = i / FPS
            if secs < edge:
                fade = secs / edge
            elif (dur - secs) < edge:
                fade = max(0.0, (dur - secs) / edge)
            if fade < 1.0:
                black = Image.new('RGB', (W, H), (0, 0, 0))
                img = Image.blend(black, img, fade)
            img.save(os.path.join(OUT_DIR, f'f{idx:05d}.png'))
            idx += 1
            if idx % 60 == 0:
                print(f'  {idx}/{frames}', flush=True)
    print(f'渲染完成 {idx} 帧')


def encode():
    cmd = [
        'ffmpeg', '-y', '-framerate', str(FPS),
        '-i', os.path.join(OUT_DIR, 'f%05d.png'),
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-crf', '18', '-preset', 'slow',
        '-movflags', '+faststart',
        VIDEO,
    ]
    print('编码中...')
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[-3000:])
        raise SystemExit(1)
    size = os.path.getsize(VIDEO) / 1024 / 1024
    print(f'完成: {VIDEO}  ({size:.1f} MB)')


if __name__ == '__main__':
    render()
    encode()
