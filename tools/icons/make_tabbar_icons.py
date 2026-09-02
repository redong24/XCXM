#!/usr/bin/env python3
"""
生成 tabBar 的 8 个 PNG（4 项 x 未选中/选中）。

为什么用脚本而不是手画或找图：
  1. 这 8 个图标是设计系统的一部分，几何参数必须可复现、可审计；
  2. 技能禁止用 emoji 顶替图标（preflight C21），现状是纯文字无图标；
  3. 风格锚在 Minimalism & Swiss Style：几何、栅格对齐、等宽线。

几何约定：
  - 画布 81x81（uni-app tabBar 推荐尺寸），内部 4 倍超采样后缩回，得到抗锯齿；
  - 线宽统一 2px（超采样下 8px），不同图标不得使用不同线宽；
  - 安全边距 10px，所有图形落在 61x61 的内框里，四个图标视觉重量对齐。

选中态的编码方式：
  颜色 + 形态同时变化（关键元素填充 / 线宽加粗），
  不单靠颜色区分状态（ux-guidelines: "Don't encode status with color alone", 严重度 High）。

用法：
  python3 tools/icons/make_tabbar_icons.py
输出：
  static/tabbar/{sentinel,ring,log,me}[-on].png
"""

import os

from PIL import Image, ImageDraw

# token 副本。改动必须与 uni.scss / styles/tokens.uts 同步。
INK_2 = "#5A6468"        # 未选中
ACCENT = "#2C6E8F"       # 选中
INK = "#14181A"          # 品牌标记的标记针
ZONE_GREEN = "#1F8A5F"   # 安全区
ZONE_AMBER = "#C9821B"   # 关注区
ZONE_RED = "#C43A2F"     # 红区

SIZE = 81
S = 4                    # 超采样倍数
N = SIZE * S             # 324
W = 2 * S                # 线宽 2px
PAD = 10 * S             # 安全边距
BOX = N - 2 * PAD        # 内框 61px

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "static", "tabbar",
)


def canvas():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def finish(img, name):
    out = img.resize((SIZE, SIZE), Image.LANCZOS)
    path = os.path.join(OUT_DIR, name + ".png")
    out.save(path, "PNG", optimize=True)
    return path


# ---------------------------------------------------------------- 哨兵
def icon_sentinel(color, on):
    """
    哨兵条的缩影：一条三分区的横向量表 + 上方一个当前位置标记。
    与首页 signature（The Sentinel Bar）同源，所以 tab 图标本身就在讲产品承诺。
    """
    img, d = canvas()
    bar_h = 18 * S
    left, right = PAD, PAD + BOX
    # 整体（标记 + 量表）在画布内垂直居中，避免图标视觉重心下坠
    tip = 6 * S
    gap = 3 * S
    total = tip + gap + bar_h
    top = (N - total) // 2 + tip + gap
    r = 3 * S

    if on:
        # 选中：量表填实，分隔线留白反刻
        d.rounded_rectangle([left, top, right, top + bar_h], radius=r, fill=color)
        for f in (0.36, 0.68):
            x = left + int(BOX * f)
            d.line([x, top, x, top + bar_h], fill=(0, 0, 0, 0), width=W)
    else:
        d.rounded_rectangle(
            [left, top, right, top + bar_h], radius=r, outline=color, width=W
        )
        for f in (0.36, 0.68):
            x = left + int(BOX * f)
            d.line([x, top + W, x, top + bar_h - W], fill=color, width=W)

    # 当前位置标记：一个贴住量表上沿的下指三角（不是带杆的箭头，
    # 带杆会被读成「下载」）
    mx = left + int(BOX * 0.80)
    d.polygon(
        [(mx - tip, top - gap - tip), (mx + tip, top - gap - tip), (mx, top - gap)],
        fill=color,
    )
    return img


# ---------------------------------------------------------------- 戒指
def icon_ring(color, on):
    """
    戒指本体：一个圆环，底部内侧缺一段（传感器窗口）。
    缺口而不是加一段粗弧：粗弧在 81px 下会糊成污点，缺口在任何尺寸下都清晰，
    而且「环上有个窗口」正是这枚戒指的真实特征。
    """
    img, d = canvas()
    cx = cy = N // 2
    band = 7 * S
    ro = int(BOX * 0.44)
    # 环带的中线半径。整枚戒指画成一段圆弧，用线宽表达环带厚度，
    # 这样无论粗细都不会出现内外圈封边造成的尖齿。
    rm = ro - band // 2

    # 传感器窗口的角度区间（图像坐标系里 90 度为正下方）
    g0, g1 = 66, 114
    stroke = band if on else W

    d.arc(
        [cx - rm, cy - rm, cx + rm, cy + rm],
        start=g1, end=360 + g0, fill=color, width=stroke,
    )

    # 窗口里的传感器：一小段同心短弧。未选中态也画，
    # 让这枚图标不会退化成一个普通的空心圆（与「我」的头部撞形）。
    rs = rm - band
    d.arc(
        [cx - rs, cy - rs, cx + rs, cy + rs],
        start=g0 + 4, end=g1 - 4, fill=color, width=W if not on else W + S,
    )
    return img


# ---------------------------------------------------------------- 日志
def icon_log(color, on):
    """
    预警时间线：一根竖轴 + 三个时间节点，右侧长度不等的条代表条目。
    刻意不画成通用的「三行列表」，那是任何 APP 都能用的形状。
    """
    img, d = canvas()
    axis_x = PAD + 6 * S
    d.line([axis_x, PAD, axis_x, PAD + BOX], fill=color, width=W)

    rows = [(0.14, 0.92), (0.50, 0.62), (0.86, 0.78)]
    dot = 5 * S
    for i, (fy, flen) in enumerate(rows):
        y = PAD + int(BOX * fy)
        # 中间那个节点是「当前」，实心；其余空心。选中态全部实心。
        solid = on or i == 1
        if solid:
            d.ellipse([axis_x - dot, y - dot, axis_x + dot, y + dot], fill=color)
        else:
            d.ellipse(
                [axis_x - dot, y - dot, axis_x + dot, y + dot],
                outline=color, width=W, fill=(0, 0, 0, 0),
            )
        x0 = axis_x + dot + 6 * S
        x1 = PAD + int(BOX * flen)
        d.line([x0, y, x1, y], fill=color, width=W if not on else W + S)
    return img


# ---------------------------------------------------------------- 我
def icon_me(color, on):
    """
    看护人：一个头 + 肩线。
    这是平台约定俗成的形状，不是 AI 味；此处保持最克制的画法，不加任何装饰。
    """
    img, d = canvas()
    cx = N // 2
    hr = int(BOX * 0.17)
    hy = PAD + hr + 4 * S

    if on:
        d.ellipse([cx - hr, hy - hr, cx + hr, hy + hr], fill=color)
    else:
        d.ellipse([cx - hr, hy - hr, cx + hr, hy + hr], outline=color, width=W)

    sw = int(BOX * 0.40)
    sy = PAD + int(BOX * 0.62)
    bottom = PAD + BOX
    if on:
        d.pieslice(
            [cx - sw, sy, cx + sw, sy + (bottom - sy) * 2],
            start=180, end=360, fill=color,
        )
    else:
        d.arc(
            [cx - sw, sy, cx + sw, sy + (bottom - sy) * 2],
            start=180, end=360, fill=color, width=W,
        )
    return img


ICONS = [
    ("sentinel", icon_sentinel),
    ("ring", icon_ring),
    ("log", icon_log),
    ("me", icon_me),
]


# ================================================================
# 大尺寸资产：登录页品牌标记 + 手动加测页的戒指图形。
# 这两处原本是 emoji（🫁 / 💍），emoji 会随系统换脸、无法控制视觉重量，
# 而且技能明确禁止把 emoji 当图标用（preflight C21）。
# ================================================================
BIG = 240
BIG_N = BIG * S


def big_canvas():
    img = Image.new("RGBA", (BIG_N, BIG_N), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def big_finish(img, name, subdir):
    out = img.resize((BIG, BIG), Image.LANCZOS)
    d = os.path.join(os.path.dirname(OUT_DIR), subdir)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name + ".png")
    out.save(path, "PNG", optimize=True)
    return path


def brand_mark(color):
    """
    品牌标记 = 哮喘行动计划卡本身：绿 / 关注 / 红三个分区块，加一个当前位置标记。

    为什么不是同心弧、不是肺、不是心跳线：
      同心开口弧试过，它读作 wifi / 广播信号，是任何监测类产品都能用的通用形状；
      肺和心跳线是这个品类的陈词滥调。
      行动计划卡是哮喘家庭真实拥有、并且已经会读的实物（GINA 标准做法），
      它是整套设计的 ground truth，所以品牌标记就用它，不另造一个符号。

    参数 color 只用于标记针；三个分区块用各自的分区色，
    这不违反 Colour Consistency Lock：分区色是调色板里独立的一族，
    accent 仍然是界面上唯一的强调色。
    """
    img, d = big_canvas()
    pad = int(BIG_N * 0.10)
    span = BIG_N - 2 * pad
    bar_h = int(BIG_N * 0.30)
    tip = int(BIG_N * 0.075)
    gap = int(BIG_N * 0.035)
    top = (BIG_N - (tip + gap + bar_h)) // 2 + tip + gap
    r = int(BIG_N * 0.022)

    seg = span // 3
    zone_colors = [ZONE_GREEN, ZONE_AMBER, ZONE_RED]
    for i, zc in enumerate(zone_colors):
        x0 = pad + i * seg
        x1 = x0 + seg if i < 2 else pad + span
        # 只有两端倒角，中间段保持直角，读起来是一条连续的量表而不是三颗药丸
        d.rounded_rectangle([x0, top, x1, top + bar_h], radius=r, fill=zc)
        if i == 0:
            d.rectangle([x0 + r, top, x1, top + bar_h], fill=zc)
        elif i == 1:
            d.rectangle([x0, top, x1, top + bar_h], fill=zc)
        else:
            d.rectangle([x0, top, x1 - r, top + bar_h], fill=zc)
        # 分区之间用纸色发丝缝隙断开
        if i > 0:
            d.rectangle([x0 - S, top, x0 + S, top + bar_h], fill=(0, 0, 0, 0))

    # 当前位置标记：贴住量表上沿的下指三角，落在绿区偏右（安全但在看着）
    mx = pad + int(span * 0.30)
    d.polygon(
        [(mx - tip, top - gap - tip), (mx + tip, top - gap - tip), (mx, top - gap)],
        fill=color,
    )
    return img


def ring_large(color):
    """
    手动加测页的戒指图形：与 tabBar 的 ring 同构，放大并加上传感器窗口的细节。
    刻意与 brand_mark 区分（单环 vs 三环），避免两个资产在同一 APP 里互相混淆。
    """
    img, d = big_canvas()
    cx = cy = BIG_N // 2
    band = 22 * S
    ro = int(BIG_N * 0.40)
    rm = ro - band // 2
    g0, g1 = 66, 114
    d.arc([cx - rm, cy - rm, cx + rm, cy + rm],
          start=g1, end=360 + g0, fill=color, width=band)
    # 传感器窗口里的两段同心短弧，暗示光学采集面
    for k, rs in enumerate((rm - band, rm - band - 9 * S)):
        d.arc([cx - rs, cy - rs, cx + rs, cy + rs],
              start=g0 + 5, end=g1 - 5, fill=color, width=(4 - k) * S)
    return img


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    made = []
    for name, fn in ICONS:
        made.append(finish(fn(INK_2, False), name))
        made.append(finish(fn(ACCENT, True), name + "-on"))
    made.append(big_finish(brand_mark(INK), "mark", "brand"))
    made.append(big_finish(ring_large(ACCENT), "ring-lg", "icons"))
    made.append(big_finish(ring_large(INK_2), "ring-lg-idle", "icons"))
    for p in made:
        print("%7d  %s" % (os.path.getsize(p), os.path.relpath(p, os.getcwd())))
    print("total %d files" % len(made))


if __name__ == "__main__":
    main()
