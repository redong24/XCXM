#!/usr/bin/env python3
"""utscheck.py - UTS / Kotlin 编译陷阱扫描器（与 preflight.py 职责分离）

为什么要单独一个工具：
  preflight.py 的 22 项检查全部是设计与反 AI 味规则（破折号、h-screen、
  lorem ipsum、alt 文本……），**没有任何一项检查编译正确性**。
  也就是说在这个项目里，「能不能编过」这件事的机械覆盖率一直是 0，
  完全靠人工盯。而客户端已连续 4 批（C2/C3/C4/C5）没有在 HBuilderX
  编译过，每一次编译往返对用户都是真实成本。

  本文件把 Phase A 与 C2-C5 期间**真实踩到过**的编译坑固化成机械检查。
  每一条 U 检查都对应一次实际发生的编译失败或运行时崩溃，不是凭空想象。

检查项与其来源事故：
  U01  <scroll-view> 根节点闭合标签不匹配        C5 真实写错（</view> 收 scroll-view）
  U02  页面根节点不可滚动（缺 scroll-view）      官方: App 端 vdom 页面默认不可滚动
  U03  三元表达式结果推导为 string 后传字面量联合  C5 真实编译错误（const zz）
  U04  JSON.parse(...) as UTSJSONObject 裸强转    Phase A Bug#2 登录崩溃 CCE
  U05  函数使用早于声明（UTS 无函数提升）         C3/C4 踩过
  U06  模板中调用带参数的函数                    uvue 模板限制
  U07  String(x) 数字转字符串                    UTS 不支持
  U08  parseInt 传入非 string                    parseInt 仅接受 string
  U09  <script setup> 中声明 type                UTS100006
  U10  float 数值直接内插（渲染成 85.0）          C4 "3.5166 分钟前" / C5 threshold
  U11  Map.get() 结果未判空直接使用               返回 V | null
  U12  onLoad 路由参数未判空即强转 string          官方: null 强转 string 抛异常
  U13  <style> 使用后代/标签/ID 选择器            uvue 仅支持 class 选择器
  U14  CSS 使用 grid / 不支持的布局               uvue 仅 flex + absolute
  U15  函数声明当值传递（未包 arrow）              C4 踩过
  U16  同义反复条件（x != '' ? x : ''）            C4/C5 各犯一次
  U17  Composition API 误用 onShow                应为 onPageShow

用法:
  python3 utscheck.py <paths...>
  python3 utscheck.py . --json
  python3 utscheck.py pages --only U01,U03
FAIL 存在时退出码 1。
"""
import argparse, json, os, re, sys

EXTS = {".uvue", ".uts"}
SKIP_DIRS = {"node_modules", ".git", "unpackage", "dist", "build",
             "__pycache__", ".idea", ".vscode"}


def norm(p):
    return p.replace("\\", "/")


def collect(paths):
    out = []
    for p in paths:
        if os.path.isfile(p):
            if os.path.splitext(p)[1].lower() in EXTS:
                out.append(p)
        else:
            for root, dirs, files in os.walk(p):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for f in files:
                    if os.path.splitext(f)[1].lower() in EXTS:
                        out.append(os.path.join(root, f))
    return sorted(set(out))


class Finding:
    def __init__(self, cid, sev, path, line, text, reason, fix):
        self.cid, self.sev, self.path, self.line = cid, sev, norm(path), line
        self.text = text.strip()[:160]
        self.reason = reason
        self.fix = fix

    def d(self):
        return {"check": self.cid, "severity": self.sev, "file": self.path,
                "line": self.line, "excerpt": self.text,
                "reason": self.reason, "fix": self.fix}


CHECKS = {}


def check(cid, title, sev):
    def deco(fn):
        CHECKS[cid] = {"title": title, "sev": sev, "fn": fn}
        return fn
    return deco


# ---------- 通用切片工具 ----------

def strip_comments(src):
    """把注释替换为等长空白，保持行号与列号不变。
    这一步是必需的：本项目注释里大量出现被检查的字面文本
    （例如「勿回退：JSON.parse 裸强转就是 Phase A 的崩溃」），
    不剔除注释会产出成片的假阳性，而假阳性会让整个工具被忽略。"""
    out = []
    i, n = 0, len(src)
    in_line = in_block = False
    in_s = None  # 当前字符串引号
    while i < n:
        c = src[i]
        c2 = src[i:i + 2]
        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            else:
                out.append(" ")
            i += 1
        elif in_block:
            if c2 == "*/":
                in_block = False
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        elif in_s:
            out.append(c)
            if c == "\\":
                if i + 1 < n:
                    out.append(src[i + 1])
                i += 2
                continue
            if c == in_s:
                in_s = None
            i += 1
        else:
            if c2 == "//":
                in_line = True
                out.append("  ")
                i += 2
            elif c2 == "/*":
                in_block = True
                out.append("  ")
                i += 2
            elif c in "\"'`":
                in_s = c
                out.append(c)
                i += 1
            else:
                out.append(c)
                i += 1
    return "".join(out)


def block(src, tag):
    """取出 <template> / <script> / <style> 段，返回 (内容, 起始行号)。

    必须只认**行首**的段落标签，并取最后一个闭合标签。
    原因（真实 bug，本工具第一版就犯了）：
      home.uvue 第 157 行的注释里写着「值与 <style> 里的 .bar-track 宽度
      必须一致」。朴素的 re.search(r'<style[^>]*>') 会命中这个注释，
      于是把 script 段的 UTS 代码当成 CSS 去扫，U13 一口气吐出 40 多条
      「`try` 不是合法 class 选择器」这类胡话。
      一个满口假阳性的检查器会被直接忽略，比没有更糟。
    """
    om = re.search(r"^[ \t]*<" + tag + r"(?:\s[^>]*)?>[ \t]*$", src, re.M)
    if not om:
        om = re.search(r"^[ \t]*<" + tag + r"(?:\s[^>]*)?>", src, re.M)
    if not om:
        return None, 0
    cm = None
    for c in re.finditer(r"^[ \t]*</" + tag + r"\s*>", src, re.M):
        if c.start() > om.end():
            cm = c
    if cm is None:
        return None, 0
    start = om.end()
    return src[start:cm.start()], src[:start].count("\n") + 1


def lines_of(text, base=1):
    return [(base + i, l) for i, l in enumerate(text.split("\n"))]


# ---------- U01 根节点闭合标签不匹配 ----------
@check("U01", "根节点开闭标签不匹配", "FAIL")
def u01(path, src):
    res = []
    if not path.endswith(".uvue"):
        return res
    tpl, base = block(src, "template")
    if tpl is None:
        return res
    body = strip_comments(tpl)
    # 找第一个真实元素标签作为根
    m = re.search(r"<([a-zA-Z][\w-]*)", body)
    if not m:
        return res
    root = m.group(1)
    # 找最后一个闭合标签
    closes = re.findall(r"</([a-zA-Z][\w-]*)\s*>", body)
    if not closes:
        return res
    last = closes[-1]
    if last != root:
        ln = base + body[:body.rfind("</" + last)].count("\n")
        res.append(Finding(
            "U01", "FAIL", path, ln, "</%s>" % last,
            "模板根节点是 <%s>，但最后一个闭合标签是 </%s>。"
            "这类不匹配会直接导致编译失败。C5 真实发生过："
            "把根节点从 view 改成 scroll-view 后忘了改闭合标签。" % (root, last),
            "把最后一个闭合标签改为 </%s>" % root))
    return res


# ---------- U02 页面缺 scroll-view ----------
@check("U02", "页面根节点不可滚动", "FAIL")
def u02(path, src):
    res = []
    if not path.endswith(".uvue"):
        return res
    # 用 pages/ 片段判断而不是 '/pages/'：实际传入的是相对路径
    # 'pages/home/home.uvue'，没有前导斜杠。第一版写成 '/pages/' in path
    # 导致所有页面被静默跳过，U02 从未真正运行过却一直报 clean，
    # 差点让人以为 8 个页面的滚动缺陷不存在。漏报比误报更危险。
    p = norm(path)
    if not (p.startswith("pages/") or "/pages/" in p):
        return res
    tpl, base = block(src, "template")
    if tpl is None:
        return res
    body = strip_comments(tpl)
    if "scroll-view" in body or "list-view" in body or "waterflow" in body:
        return res
    # 元素数量作为溢出代理指标
    els = len(re.findall(r"<([a-zA-Z][\w-]*)", body))
    if els < 12:
        sev, why = "WARN", "元素较少，可能不溢出，但仍建议显式声明可滚动性"
    else:
        sev, why = "FAIL", "元素数 %d，几乎必然超一屏" % els
    m = re.search(r"<([a-zA-Z][\w-]*)", body)
    ln = base + body[:m.start()].count("\n") if m else base
    res.append(Finding(
        "U02", sev, path, ln, m.group(0) if m else "<template>",
        "官方文档明确：「VDOM模式中，App平台的页面默认不可滚动，"
        "需要开发者在页面中显示使用scroll-view」。本页无任何滚动容器，%s。"
        "后果是超出首屏的内容用户永远触达不到，且不会报任何错。" % why,
        "根节点改为 <scroll-view :scroll-y=\"true\"> 并同步改闭合标签"))
    return res


# ---------- U03 三元表达式推导为 string ----------
@check("U03", "三元表达式结果未标注联合类型", "FAIL")
def u03(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    # 只有当三元的结果**流向联合类型形参**时才是编译错误。
    # 形如 const path = cond ? '/api/a' : '/api/b' 是完全合法的，
    # 对它报警只会制造噪音。所以先收集本项目真实存在的联合类型消费者，
    # 再看变量是否被喂给它们。
    UNION_SINKS = ("zoneColor", "zoneWash", "zoneLabel", "planStepsFor",
                   "planDisclaimer", "sentinelLabel", "sentinelColor")
    pat = re.compile(
        r"\b(const|let)\s+([A-Za-z_]\w*)\s*=\s*[^;\n]*\?\s*"
        r"(['\"])([^'\"]+)\3\s*:\s*[^;\n]*(['\"])")
    for ln, l in lines_of(body, base):
        m = pat.search(l)
        if not m:
            continue
        if ":" in l.split("=")[0]:  # 已有类型标注
            continue
        var = m.group(2)
        # 该变量后续是否被传给联合类型形参
        sink = None
        for sl in body.split("\n"):
            for fn in UNION_SINKS:
                if re.search(re.escape(fn) + r"\s*\(\s*" + re.escape(var)
                             + r"\s*[,)]", sl):
                    sink = fn
                    break
            if sink:
                break
        if sink is None:
            continue
        res.append(Finding(
            "U03", "FAIL", path, ln, l,
            "三元表达式的结果会被推导成 string，而不是字面量联合类型，"
            "但 `%s` 随后被传给 %s()，其形参是联合类型。"
            "Kotlin 严格类型下这会直接编译失败。C5 真实踩到过。" % (var, sink),
            "显式标注类型，例如 const %s: Zone = ..." % var))
    return res


# ---------- U04 JSON.parse 裸强转 ----------
@check("U04", "JSON.parse 裸强转（CCE 隐患）", "FAIL")
def u04(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    pat = re.compile(r"JSON\.parse\s*\([^)]*\)\s*as\s+(UTSJSONObject|\w+)")
    for ln, l in lines_of(body, base):
        m = pat.search(l)
        if not m:
            continue
        res.append(Finding(
            "U04", "FAIL", path, ln, l,
            "JSON.parse 在 Android/Kotlin 侧返回 UTSJSONObject，裸强转就是 "
            "Phase A 那个登录崩溃（UTSJSONObject cannot be cast to TokenResp）"
            "的同一个 ClassCastException 隐患。",
            "改用 common/request.uts 的 asObject() / asObjectArray()，二者内部带 try/catch"))
    return res


# ---------- U05 函数使用早于声明 ----------
@check("U05", "函数使用早于声明（UTS 无函数提升）", "FAIL")
def u05(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    decl = {}
    for ln, l in lines_of(body, base):
        m = re.search(r"^\s*(?:export\s+)?function\s+([A-Za-z_]\w*)", l)
        if m and m.group(1) not in decl:
            decl[m.group(1)] = ln
    if not decl:
        return res
    for ln, l in lines_of(body, base):
        if re.search(r"^\s*(?:export\s+)?function\s", l):
            continue
        for name, dln in decl.items():
            if ln >= dln:
                continue
            if re.search(r"\b" + re.escape(name) + r"\s*\(", l):
                res.append(Finding(
                    "U05", "FAIL", path, ln, l,
                    "UTS 没有函数提升，调用 %s() 出现在其声明（第 %d 行）之前，"
                    "会编译失败。" % (name, dln),
                    "把 %s 的声明移到第一次调用之前" % name))
    return res


# ---------- U06 模板中调用带参函数 ----------
@check("U06", "模板中调用带参数的函数", "FAIL")
def u06(path, src):
    res = []
    if not path.endswith(".uvue"):
        return res
    tpl, base = block(src, "template")
    if tpl is None:
        return res
    body = strip_comments(tpl)
    for ln, l in lines_of(body, base):
        # {{ fn(arg) }} 形式，排除空参与事件绑定
        for m in re.finditer(r"\{\{([^}]*)\}\}", l):
            expr = m.group(1)
            fm = re.search(r"\b([A-Za-z_]\w*)\s*\(\s*[^)\s]", expr)
            if not fm:
                continue
            if fm.group(1) in ("Math", "Number", "String", "JSON"):
                continue
            res.append(Finding(
                "U06", "FAIL", path, ln, expr,
                "uvue 模板不支持调用带参数的函数（%s(...)）。" % fm.group(1),
                "在 script 中用 computed 预先算好，模板只读取结果"))
    return res


# ---------- U07 String(x) ----------
@check("U07", "String() 转换不受支持", "FAIL")
def u07(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    for ln, l in lines_of(body, base):
        if re.search(r"(?<![\w.])String\s*\(", l):
            res.append(Finding(
                "U07", "FAIL", path, ln, l,
                "UTS 不支持用 String() 做数字转字符串。",
                "改用模板字符串 `${x}`"))
    return res


# ---------- U08 parseInt 非 string 入参 ----------
@check("U08", "parseInt 传入非 string", "WARN")
def u08(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    # 先把本文件里能确定为 string 的标识符收集起来，避免对已是 string 的
    # 实参报警。normalizeAge(raw: string) 与 ref<string> 都属于这类，
    # 对它们报警纯属噪音。
    known_str = set(re.findall(r"([A-Za-z_]\w*)\s*:\s*string\b", body))
    known_str |= set(re.findall(
        r"(?:const|let)\s+([A-Za-z_]\w*)\s*=\s*ref<string>", body))
    for ln, l in lines_of(body, base):
        for m in re.finditer(r"parseInt\s*\(\s*([^,)]+)", l):
            arg = m.group(1).strip()
            if arg.startswith("`") or arg.startswith("'") or arg.startswith('"'):
                continue
            root = arg.split(".")[0]
            # x.value 形式：若 x 是 ref<string>，则 x.value 是 string
            if root in known_str or arg in known_str:
                continue
            if re.match(r"^[A-Za-z_]\w*(\.\w+)*$", arg):
                res.append(Finding(
                    "U08", "WARN", path, ln, l,
                    "parseInt 只接受 string 入参，实参 `%s` 未在本文件内"
                    "确定为 string。若它是 any 或数字，编译期或运行期都可能出问题。"
                    % arg,
                    "改为 parseInt(`${%s}`)" % arg))
    return res


# ---------- U09 script setup 中声明 type ----------
@check("U09", "<script setup> 中声明 type（UTS100006）", "FAIL")
def u09(path, src):
    res = []
    if not path.endswith(".uvue"):
        return res
    m = re.search(r"<script[^>]*\bsetup\b[^>]*>(.*?)</script>", src, re.S)
    if not m:
        return res
    base = src[:m.start(1)].count("\n") + 1
    body = strip_comments(m.group(1))
    for ln, l in lines_of(body, base):
        if re.search(r"^\s*(?:export\s+)?type\s+[A-Za-z_]\w*\s*=", l):
            res.append(Finding(
                "U09", "FAIL", path, ln, l,
                "UTS100006：不能在 <script setup> 中声明 type。",
                "把 type 移到 types/ 目录下的 .uts 文件并 import type"))
    return res


# ---------- U10 float 直接内插 ----------
@check("U10", "疑似 float 数值直接内插（渲染成 85.0）", "WARN")
def u10(path, src):
    res = []
    # 数据库 float 列名：这些字段渲染时必须取整
    FLOATY = ("value", "threshold", "hr", "bo", "spo2", "hrv", "temperature")
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    tpl, tbase = block(src, "template") if path.endswith(".uvue") else (None, 0)
    chunks = [(code, base)] if code else []
    if tpl:
        chunks.append((tpl, tbase))
    for chunk, cb in chunks:
        body = strip_comments(chunk)
        for ln, l in lines_of(body, cb):
            if "Math.round" in l or "Math.floor" in l or "toFixed" in l:
                continue
            for m in re.finditer(r"\$\{\s*([A-Za-z_][\w.\[\]'\"]*)\s*\}", l):
                expr = m.group(1)
                leaf = re.split(r"[.\[\]'\"]+", expr)[-1] or expr
                if leaf.lower() in FLOATY:
                    res.append(Finding(
                        "U10", "WARN", path, ln, l,
                        "`%s` 疑似来自数据库 float 列。number 在 UTS 里是浮点，"
                        "直接内插会在 Kotlin 侧渲染成「85.0」而不是「85」。"
                        "C4 的「3.5166 分钟前」与 C5 的阈值渲染都是这个问题。" % expr,
                        "包一层 Math.round(%s)" % expr))
            for m in re.finditer(r"\{\{\s*([A-Za-z_][\w.\[\]'\"]*)\s*\}\}", l):
                expr = m.group(1)
                leaf = re.split(r"[.\[\]'\"]+", expr)[-1] or expr
                if leaf.lower() in FLOATY:
                    res.append(Finding(
                        "U10", "WARN", path, ln, l,
                        "`%s` 疑似 float 列，模板直接渲染会出现小数点。" % expr,
                        "在 script 中先 Math.round 后再渲染"))
    return res


# ---------- U11 Map.get 未判空 ----------
@check("U11", "Map.get() 结果未判空", "WARN")
def u11(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    # 只盯真正的 Map 变量。项目里 uni.getStorageSync 之类同名方法很多，
    # 对所有 .get( 报警会把有效信号淹掉。
    maps = set(re.findall(
        r"(?:const|let)\s+([A-Za-z_]\w*)\s*(?::\s*Map<[^>]*>)?\s*=\s*new\s+Map",
        body))
    maps |= set(re.findall(r"([A-Za-z_]\w*)\s*:\s*Map<", body))
    if not maps:
        return res
    all_lines = body.split("\n")
    for idx, l in enumerate(all_lines):
        ln = base + idx
        for name in maps:
            for m in re.finditer(re.escape(name) + r"\.get\s*\([^)]*\)", l):
                tail = l[m.end():m.end() + 6]
                if tail.startswith("!") or "??" in tail:
                    continue
                # 取回值后在紧邻几行内判空再用 ! 是正确写法，不能报警。
                # children.uvue 就是这么写的（const prev = map.get(x)
                # 紧跟 if (prev == null || a.level > prev!)），
                # 只看单行会把正确代码判成错误。
                vm = re.search(r"(?:const|let)\s+([A-Za-z_]\w*)\s*=\s*$"
                               .replace("$", ""), l[:m.start()])
                guarded = False
                if vm:
                    var = vm.group(1)
                    win = "\n".join(all_lines[idx:idx + 4])
                    if re.search(re.escape(var) + r"\s*(==|!=)\s*null", win) \
                       or re.search(re.escape(var) + r"!", win):
                        guarded = True
                if guarded:
                    continue
                res.append(Finding(
                    "U11", "WARN", path, ln, l,
                    "Map.get() 返回 V | null。`%s` 是 Map，此处未加 ! 或 "
                    "?? 默认值，且紧邻几行内未见判空，"
                    "后续当非空使用会在 Kotlin 严格空安全下编译失败。"
                    % name,
                    "改为 %s.get(k)! 或 %s.get(k) ?? 默认值" % (name, name)))
    return res


# ---------- U12 onLoad 参数未判空 ----------
@check("U12", "onLoad 路由参数未判空即强转", "FAIL")
def u12(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    for ln, l in lines_of(body, base):
        if re.search(r"options\s*\[[^\]]+\]\s*as\s+string", l):
            res.append(Finding(
                "U12", "FAIL", path, ln, l,
                "官方文档明确：「当值为 null 的时，强制转换为 string 会引发异常」。"
                "路由参数下标取值返回 any | null，缺参时这行会抛异常。",
                "先判 null，再用模板字符串取字面量"))
    return res


# ---------- U13 非 class 选择器 ----------
@check("U13", "style 使用了非 class 选择器", "FAIL")
def u13(path, src):
    res = []
    if not path.endswith(".uvue"):
        return res
    sty, base = block(src, "style")
    if sty is None:
        return res
    body = strip_comments(sty)
    for ln, l in lines_of(body, base):
        s = l.strip()
        if not s or "{" not in s:
            continue
        sel = s.split("{")[0].strip()
        if not sel or sel.startswith("@") or sel.startswith("$"):
            continue
        if ":" in sel and not sel.startswith("."):
            continue
        for part in sel.split(","):
            p = part.strip()
            if not p:
                continue
            if p.startswith("#"):
                res.append(Finding(
                    "U13", "FAIL", path, ln, l,
                    "uvue 只支持 class 选择器，不支持 ID 选择器。",
                    "改为 class 选择器"))
            elif re.match(r"^\.[\w-]+$", p):
                continue
            elif re.match(r"^[\w-]+$", p):
                res.append(Finding(
                    "U13", "FAIL", path, ln, l,
                    "uvue 只支持 class 选择器，不支持标签选择器 `%s`。" % p,
                    "改为 class 选择器"))
            elif " " in p or ">" in p:
                res.append(Finding(
                    "U13", "FAIL", path, ln, l,
                    "uvue 不支持后代/子代选择器（`%s`）。样式也不继承。" % p,
                    "拆成独立 class 直接标注在元素上"))
    return res


# ---------- U14 grid 布局 ----------
@check("U14", "使用 uvue 不支持的布局", "FAIL")
def u14(path, src):
    res = []
    if not path.endswith(".uvue"):
        return res
    sty, base = block(src, "style")
    if sty is None:
        return res
    body = strip_comments(sty)
    for ln, l in lines_of(body, base):
        if re.search(r"display\s*:\s*(grid|inline-grid|table|inline-block)", l):
            res.append(Finding(
                "U14", "FAIL", path, ln, l,
                "uvue 的 CSS 子集只支持 flex 与 absolute 布局。",
                "改用 flex 实现"))
        if re.search(r"^\s*grid-(template|column|row|area|gap)", l):
            res.append(Finding(
                "U14", "FAIL", path, ln, l,
                "uvue 不支持 CSS Grid 相关属性。",
                "改用 flex 实现"))
    return res


# ---------- U15 函数声明当值传递 ----------
@check("U15", "函数声明直接当值传递", "WARN")
def u15(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    names = set(re.findall(r"^\s*(?:export\s+)?function\s+([A-Za-z_]\w*)",
                           body, re.M))
    if not names:
        return res
    # 只看真正接受回调的位置。否则 foo(bar) 这种普通传参会被全量误报，
    # 而项目里绝大多数 foo(bar) 传的是数据不是函数。
    CB_HOSTS = ("onLoad", "onReady", "onPageShow", "onPageHide", "onMounted",
                "onUnmounted", "onShow", "onHide", "setTimeout", "setInterval",
                "then", "catch", "finally", "watch", "nextTick",
                "addEventListener", "forEach", "map", "filter", "sort")
    host_re = "|".join(re.escape(h) for h in CB_HOSTS)
    for ln, l in lines_of(body, base):
        for m in re.finditer(r"\b(" + host_re + r")\s*\(([^)]*)\)", l):
            args = m.group(2)
            for n in names:
                if re.search(r"(^|[,\s])" + re.escape(n) + r"\s*($|,)", args):
                    res.append(Finding(
                        "U15", "WARN", path, ln, l,
                        "UTS 中函数声明不能直接作为值传递，"
                        "这里把 %s 直接交给了 %s()。" % (n, m.group(1)),
                        "包一层箭头函数：() => %s()" % n))
    return res


# ---------- U16 同义反复条件 ----------
@check("U16", "同义反复的三元条件", "WARN")
def u16(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    pat = re.compile(r"([A-Za-z_][\w.]*)\s*!=\s*(''|\"\")\s*\?\s*"
                     r"\1\s*:\s*(''|\"\")")
    for ln, l in lines_of(body, base):
        if pat.search(l):
            res.append(Finding(
                "U16", "WARN", path, ln, l,
                "x != '' ? x : '' 是同义反复，两个分支结果相同，"
                "说明这里的意图没有被真正表达出来。C4 与 C5 各犯过一次。",
                "直接用 x，或改用 ?? 提供真正的默认值"))
    return res


# ---------- U17 onShow 误用 ----------
@check("U17", "Composition API 误用 onShow", "FAIL")
def u17(path, src):
    res = []
    code, base = (src, 1) if path.endswith(".uts") else block(src, "script")
    if code is None:
        return res
    body = strip_comments(code)
    for ln, l in lines_of(body, base):
        if re.search(r"(?<![\w.])onShow\s*\(", l):
            res.append(Finding(
                "U17", "FAIL", path, ln, l,
                "Composition API 里页面显示回调是 onPageShow。"
                "onShow 属于应用级生命周期，两者在页面中会冲突。",
                "改为 onPageShow"))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--only", default="")
    ap.add_argument("--ignore", default="")
    a = ap.parse_args()

    only = {x.strip().upper() for x in a.only.split(",") if x.strip()}
    ignore = {x.strip().upper() for x in a.ignore.split(",") if x.strip()}
    active = [c for c in sorted(CHECKS)
              if (not only or c in only) and c not in ignore]

    files = collect(a.paths)
    findings = []
    for p in files:
        try:
            src = open(p, encoding="utf-8").read()
        except Exception:
            continue
        for cid in active:
            try:
                findings.extend(CHECKS[cid]["fn"](p, src) or [])
            except Exception as e:
                findings.append(Finding(cid, "WARN", p, 1, "",
                                        "检查自身抛异常: %r" % e,
                                        "修 utscheck.py"))

    nf = sum(1 for f in findings if f.sev == "FAIL")
    nw = sum(1 for f in findings if f.sev == "WARN")
    ni = sum(1 for f in findings if f.sev == "INFO")

    if a.json:
        print(json.dumps({"files": len(files), "checks": len(active),
                          "fail": nf, "warn": nw, "info": ni,
                          "findings": [f.d() for f in findings]},
                         ensure_ascii=False, indent=2))
        return 1 if nf else 0

    bar = "=" * 78
    print(bar)
    print("UTS-CHECK  files=%d  checks=%d  FAIL=%d  WARN=%d  INFO=%d"
          % (len(files), len(active), nf, nw, ni))
    print(bar)
    if not findings:
        print("No findings. All active checks pass.")
    else:
        order = {"FAIL": 0, "WARN": 1, "INFO": 2}
        for f in sorted(findings, key=lambda x: (order[x.sev], x.path, x.line)):
            print("\n[%s] %s  %s:%d" % (f.sev, f.cid, f.path, f.line))
            if f.text:
                print("    > %s" % f.text)
            print("    因为: %s" % f.reason)
            print("    改法: %s" % f.fix)
    clean = [c for c in active
             if not any(f.cid == c for f in findings)]
    print("\nclean checks (%d): %s" % (len(clean), ", ".join(clean)))
    return 1 if nf else 0


if __name__ == "__main__":
    sys.exit(main())
