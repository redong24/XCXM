#!/usr/bin/env python3
"""
preflight.py - Mechanical anti-slop scanner, 22 checks C01-C22.

Faithful reimplementation of the szyj-ui-design-workflow Phase 5.1 scanner
contract (SKILL.md check table) against the verbatim upstream rule text in
Leonxlnx/taste-skill SKILL.md sections 4.x / 9.x.

Adapted for uni-app x: scans .uvue / .uts / .vue / .json / .scss / .css /
.ts / .tsx / .js / .jsx / .html. uvue-specific notes are attached to the
checks whose web assumptions do not hold (C02, C19).

Usage:
  python3 preflight.py <paths...>
  python3 preflight.py src/ --json
  python3 preflight.py src/ --only C01,C21
  python3 preflight.py src/ --ignore C03
Exit code 1 if any FAIL.
"""
import argparse, json, os, re, sys

EXTS = {".uvue",".uts",".vue",".ts",".tsx",".js",".jsx",".html",".htm",
        ".css",".scss",".sass",".json",".md"}
SKIP_DIRS = {"node_modules",".git","unpackage","dist","build","__pycache__",".idea",".vscode"}

# Emoji ranges used as UI iconography (C21). Excludes CJK, excludes text punctuation.
EMOJI_RE = re.compile(
    "["
    "\U0001F300-\U0001F5FF"  # symbols & pictographs
    "\U0001F600-\U0001F64F"  # emoticons
    "\U0001F680-\U0001F6FF"  # transport & map
    "\U0001F700-\U0001F77F"
    "\U0001F900-\U0001F9FF"  # supplemental symbols (incl. body parts / organs)
    "\U0001FA70-\U0001FAFF"  # extended-A (includes lungs U+1FAC1)
    "\u2600-\u26FF"          # misc symbols
    "\u2700-\u27BF"          # dingbats
    "\u2B00-\u2BFF"
    "]"
)

BANNED_VERBS = [
    "unleash","supercharge","revolutionize","revolutionise","transform your",
    "elevate your","seamlessly","effortlessly","game-changing","cutting-edge",
    "next-level","unlock the power","harness the power","take it to the next level",
    "empower your","skyrocket","turbocharge",
]
FAKE_NAMES = ["john doe","jane doe","acme corp","acme inc","acme,","nexus","lorem corp","foo bar"]
PERFECT_METRICS = re.compile(r"\b(99\.9{1,3}\s*%|100\s*%\s*(uptime|accurate|accuracy|satisfaction)|10x\s+faster)\b", re.I)

def norm(p): return p.replace("\\","/")

def collect(paths):
    out=[]
    for p in paths:
        if os.path.isfile(p):
            if os.path.splitext(p)[1].lower() in EXTS: out.append(p)
        else:
            for root,dirs,files in os.walk(p):
                dirs[:]=[d for d in dirs if d not in SKIP_DIRS]
                for f in files:
                    if os.path.splitext(f)[1].lower() in EXTS:
                        out.append(os.path.join(root,f))
    return sorted(set(out))

class Finding:
    def __init__(self,cid,sev,path,line,text,reason,fix):
        self.cid,self.sev,self.path,self.line=cid,sev,norm(path),line
        self.text=text.strip()[:160]; self.reason=reason; self.fix=fix
    def d(self):
        return {"check":self.cid,"severity":self.sev,"file":self.path,"line":self.line,
                "excerpt":self.text,"reason":self.reason,"fix":self.fix}

CHECKS={}
def check(cid,title,sev):
    def deco(fn):
        CHECKS[cid]={"title":title,"sev":sev,"fn":fn}; return fn
    return deco

# ---------------- C01 em-dash / en-dash ----------------
@check("C01","em-dash / en-dash","FAIL")
def c01(path,lines,src,res):
    is_md = path.lower().endswith(".md")
    for i,l in enumerate(lines,1):
        if "\u2014" in l or "\u2013" in l:
            res.append(Finding("C01","WARN" if is_md else "FAIL",path,i,l,
                "Em-dash/en-dash is the #1 LLM typography tell (taste-skill 9.G, zero tolerance).",
                "Replace with a period, comma, colon, parentheses, or a plain hyphen '-'."))

# ---------------- C02 h-screen / 100vh ----------------
@check("C02","h-screen / 100vh","FAIL")
def c02(path,lines,src,res):
    # .md files legitimately quote the rule text itself (design docs).
    if path.lower().endswith(".md"): return
    for i,l in enumerate(lines,1):
        if re.search(r"\bh-screen\b",l) or re.search(r"\b100vh\b",l):
            res.append(Finding("C02","FAIL",path,i,l,
                "h-screen/100vh jumps when the mobile address bar hides.",
                "Web: min-h-[100dvh]. uvue: flex:1 on the page root (uvue has no dvh unit)."))

# ---------------- C03 default sans fonts ----------------
@check("C03","Inter / Roboto / Arial / Open Sans / Helvetica","WARN")
def c03(path,lines,src,res):
    pat=re.compile(r"font-family[^;{}]*?\b(Inter|Roboto|Arial|Open\s+Sans|Helvetica)\b",re.I)
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C03","WARN",path,i,l,
                "Inter/Roboto/Arial as the default face is the most common AI-generated type choice.",
                "Prefer Geist, Outfit, Satoshi, Cabinet Grotesk, or an explicit system-CJK stack."))

# ---------------- C04 lucide-react ----------------
@check("C04","lucide-react import","WARN")
def c04(path,lines,src,res):
    for i,l in enumerate(lines,1):
        if "lucide-react" in l:
            res.append(Finding("C04","WARN",path,i,l,
                "lucide-react is the default AI icon set (taste-skill 4.x: discouraged).",
                "Only if the user asked or the project already depends on it; else use Phosphor/Heroicons."))

# ---------------- C05 pure black ----------------
@check("C05","pure black #000000","FAIL")
def c05(path,lines,src,res):
    # .md files legitimately quote the banned value when documenting the rule.
    if path.lower().endswith(".md"): return
    pat=re.compile(r"#000000\b|#000\b|\brgb\(\s*0\s*,\s*0\s*,\s*0\s*\)")
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C05","FAIL",path,i,l,
                "Pure black reads as unconsidered; real products tint their darkest value.",
                "Use a near-black tinted toward the background hue, e.g. #14181A."))

# ---------------- C06 transition: all ----------------
@check("C06","transition: all","FAIL")
def c06(path,lines,src,res):
    pat=re.compile(r"transition\s*:\s*all\b|transition-all\b")
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C06","FAIL",path,i,l,
                "transition:all animates layout properties and causes jank.",
                "Enumerate properties: transition: opacity .2s, transform .2s."))

# ---------------- C07 z-index >= 999 ----------------
@check("C07","arbitrary z-index >= 999","WARN")
def c07(path,lines,src,res):
    for i,l in enumerate(lines,1):
        for m in re.finditer(r"z-index\s*:\s*(\d{3,})|z-\[(\d{3,})\]",l):
            v=int(m.group(1) or m.group(2))
            if v>=999:
                res.append(Finding("C07","WARN",path,i,l,
                    f"z-index {v} is an escape hatch, not a layering system.",
                    "Define a small named scale (base/raised/overlay/modal) and stay inside it."))

# ---------------- C08 scroll listener ----------------
@check("C08","window.addEventListener('scroll')","WARN")
def c08(path,lines,src,res):
    pat=re.compile(r"addEventListener\(\s*['\"]scroll['\"]")
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C08","WARN",path,i,l,
                "Raw scroll listeners fire per frame on the main thread.",
                "Use IntersectionObserver, or uvue's @scroll with a throttle."))

# ---------------- C09 lorem ipsum ----------------
@check("C09","Lorem ipsum","FAIL")
def c09(path,lines,src,res):
    pat=re.compile(r"lorem\s+ipsum|dolor\s+sit\s+amet",re.I)
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C09","FAIL",path,i,l,
                "Placeholder latin shipped to users.",
                "Write the real copy, even if short."))

# ---------------- C10 banned marketing verbs ----------------
@check("C10","banned marketing verbs","WARN")
def c10(path,lines,src,res):
    for i,l in enumerate(lines,1):
        low=l.lower()
        for v in BANNED_VERBS:
            if v in low:
                res.append(Finding("C10","WARN",path,i,l,
                    f"'{v}' is LLM marketing filler.",
                    "State the concrete benefit in plain language."))
                break

# ---------------- C11 fake names ----------------
@check("C11","John Doe / Acme / Nexus","WARN")
def c11(path,lines,src,res):
    for i,l in enumerate(lines,1):
        low=l.lower()
        for n in FAKE_NAMES:
            if n in low:
                res.append(Finding("C11","WARN",path,i,l,
                    f"Placeholder identity '{n}'.",
                    "Use realistic, locale-appropriate names."))
                break

# ---------------- C12 eyebrow overuse ----------------
@check("C12","eyebrow overuse (ratio rule)","WARN")
def c12(path,lines,src,res):
    if not path.lower().endswith((".uvue",".vue",".html",".htm",".tsx",".jsx")): return
    eyebrow=len(re.findall(r'class="[^"]*\b(eyebrow|kicker|overline|section-label)\b',src))
    heads=len(re.findall(r"<(h1|h2|h3)\b",src))+len(re.findall(r'class="[^"]*\b(title|headline|heading)\b',src))
    if eyebrow>=3 and heads and eyebrow/max(heads,1)>0.6:
        res.append(Finding("C12","WARN",path,1,f"{eyebrow} eyebrows / {heads} headings",
            "An eyebrow above nearly every heading is decoration, not hierarchy.",
            "Keep eyebrows on at most one third of sections."))

# ---------------- C13 image without meaningful alt ----------------
@check("C13","image without meaningful alt","FAIL")
def c13(path,lines,src,res):
    for i,l in enumerate(lines,1):
        for m in re.finditer(r"<(img|image)\b[^>]*>",l,re.I):
            tag=m.group(0)
            am=re.search(r'\balt\s*=\s*"(.*?)"',tag,re.I)
            if am is None:
                res.append(Finding("C13","FAIL",path,i,tag,
                    "Image has no alt attribute.",
                    'Add alt="..." describing the content, or alt="" if purely decorative.'))
            elif len(am.group(1).strip())<3:
                res.append(Finding("C13","WARN",path,i,tag,
                    "alt is empty or near-empty on a content image.",
                    "Describe what the image shows."))

# ---------------- C14 outline-none without focus-visible ----------------
@check("C14","outline-none with no focus-visible","FAIL")
def c14(path,lines,src,res):
    has_fv = ("focus-visible" in src) or ("focus:ring" in src) or (":focus" in src)
    for i,l in enumerate(lines,1):
        if re.search(r"outline\s*:\s*none|outline-none",l) and not has_fv:
            res.append(Finding("C14","FAIL",path,i,l,
                "Focus outline removed with no visible replacement; keyboard users lose their place.",
                "Add a :focus-visible ring, or keep the outline."))

# ---------------- C15 fake-perfect metrics ----------------
@check("C15","fake-perfect metrics (99.99%)","WARN")
def c15(path,lines,src,res):
    for i,l in enumerate(lines,1):
        if PERFECT_METRICS.search(l):
            res.append(Finding("C15","WARN",path,i,l,
                "Suspiciously round/perfect metric reads as invented.",
                "Use a real measured number, or drop the claim."))

# ---------------- C16 border-t + border-b hairline rows ----------------
@check("C16","border-t + border-b hairline rows","WARN")
def c16(path,lines,src,res):
    for i,l in enumerate(lines,1):
        if re.search(r"\bborder-t\b",l) and re.search(r"\bborder-b\b",l):
            res.append(Finding("C16","WARN",path,i,l,
                "Both top and bottom hairlines on the same row is the laziest list layout (taste-skill 9.x).",
                "Pick one edge, or use divide-y on the container."))

# ---------------- C17 animating layout properties ----------------
@check("C17","animating top/left/width/height","FAIL")
def c17(path,lines,src,res):
    pat=re.compile(r"transition\s*:\s*[^;{}]*\b(top|left|right|bottom|width|height|margin|padding)\b")
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C17","FAIL",path,i,l,
                "Animating layout properties triggers reflow every frame.",
                "Animate transform and opacity instead."))

# ---------------- C18 duplicate CTA intent ----------------
@check("C18","duplicate CTA intent","WARN")
def c18(path,lines,src,res):
    if not path.lower().endswith((".uvue",".vue",".html",".htm",".tsx",".jsx")): return
    labels=[m.group(1).strip() for m in re.finditer(r"<(?:button|text)[^>]*>([^<>{}]{2,24})</(?:button|text)>",src)]
    seen={}
    for lb in labels:
        k=re.sub(r"\s+","",lb)
        if len(k)<2: continue
        seen[k]=seen.get(k,0)+1
    for k,c in seen.items():
        if c>=3:
            res.append(Finding("C18","WARN",path,1,f'"{k}" x{c}',
                "The same action label repeated many times splits user intent.",
                "Keep one primary CTA per screen; make the rest secondary or distinct."))

# ---------------- C19 flexbox percentage math ----------------
@check("C19","flexbox percentage math","WARN")
def c19(path,lines,src,res):
    uvue = path.lower().endswith((".uvue",".uts"))
    pat=re.compile(r"(flex|display)\s*:\s*flex[^}]{0,200}?(width|flex-basis)\s*:\s*\d{1,3}(\.\d+)?%",re.S)
    for m in pat.finditer(src):
        line=src[:m.start()].count("\n")+1
        if uvue:
            res.append(Finding("C19","INFO",path,line,m.group(0)[:120],
                "Flex + percentage width is a web AI tell, but uvue has no CSS Grid, so flex is the only option.",
                "uvue: prefer flex:1 / fixed px over percentage widths; justified here if percentages are unavoidable."))
        else:
            res.append(Finding("C19","WARN",path,line,m.group(0)[:120],
                "Percentage widths inside flex containers instead of a real grid.",
                "Use CSS Grid with fr units."))

# ---------------- C20 unresolved image slot ----------------
@check("C20","unresolved image slot","FAIL")
def c20(path,lines,src,res):
    pat=re.compile(r"TODO[^\n]{0,60}(image|img|photo|asset|icon)|(image|img|photo)[^\n]{0,20}TODO|placeholder\.(png|jpg|svg)|via\.placeholder",re.I)
    for i,l in enumerate(lines,1):
        if pat.search(l):
            res.append(Finding("C20","FAIL",path,i,l,
                "Unresolved image slot left in shipped code.",
                "Generate or source the real asset."))

# ---------------- C21 emoji as UI iconography ----------------
@check("C21","emoji as UI iconography","FAIL")
def c21(path,lines,src,res):
    if path.lower().endswith(".md"): return
    for i,l in enumerate(lines,1):
        s=l.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"): continue
        for m in EMOJI_RE.finditer(l):
            res.append(Finding("C21","FAIL",path,i,l,
                f"Emoji U+{ord(m.group(0)):04X} used as interface iconography.",
                "Replace with a real vector icon asset (PNG/SVG) or a text label."))
            break

# ---------------- C22 hand-rolled SVG icon paths ----------------
@check("C22","hand-rolled SVG icon paths","WARN")
def c22(path,lines,src,res):
    for m in re.finditer(r"<path\b[^>]*\bd\s*=\s*\"([^\"]{40,})\"",src):
        line=src[:m.start()].count("\n")+1
        res.append(Finding("C22","WARN",path,line,m.group(0)[:100],
            "Hand-written SVG path data is usually a mangled or invented icon.",
            "Use a real icon set export."))

SEV_ORDER={"FAIL":0,"WARN":1,"INFO":2}

def main():
    ap=argparse.ArgumentParser(description="Mechanical anti-slop scanner, 22 checks C01-C22")
    ap.add_argument("paths",nargs="+")
    ap.add_argument("--json",action="store_true")
    ap.add_argument("--only",default="")
    ap.add_argument("--ignore",default="")
    a=ap.parse_args()
    only={x.strip().upper() for x in a.only.split(",") if x.strip()}
    ign={x.strip().upper() for x in a.ignore.split(",") if x.strip()}
    active=[c for c in sorted(CHECKS) if (not only or c in only) and c not in ign]

    files=collect(a.paths)
    res=[]
    for f in files:
        try:
            src=open(f,encoding="utf-8",errors="replace").read()
        except Exception:
            continue
        lines=src.split("\n")
        for cid in active:
            try: CHECKS[cid]["fn"](f,lines,src,res)
            except Exception as e:
                print(f"[scanner-error] {cid} on {f}: {e}",file=sys.stderr)

    res.sort(key=lambda x:(SEV_ORDER.get(x.sev,3),x.cid,x.path,x.line))
    fails=[r for r in res if r.sev=="FAIL"]
    warns=[r for r in res if r.sev=="WARN"]
    infos=[r for r in res if r.sev=="INFO"]

    if a.json:
        print(json.dumps({"files_scanned":len(files),"checks_run":active,
            "fail":len(fails),"warn":len(warns),"info":len(infos),
            "findings":[r.d() for r in res]},ensure_ascii=False,indent=2))
    else:
        print("="*78)
        print(f"PRE-FLIGHT  files={len(files)}  checks={len(active)}  "
              f"FAIL={len(fails)}  WARN={len(warns)}  INFO={len(infos)}")
        print("="*78)
        cur=None
        for r in res:
            if r.cid!=cur:
                cur=r.cid
                print(f"\n[{r.cid}] {CHECKS[r.cid]['title']}")
            print(f"  {r.sev:4} {r.path}:{r.line}")
            if r.text: print(f"       > {r.text}")
            print(f"       reason: {r.reason}")
            print(f"       fix:    {r.fix}")
        if not res: print("\nNo findings. All active checks pass.")
        print()
        clean=[c for c in active if not any(r.cid==c for r in res)]
        print(f"clean checks ({len(clean)}): {', '.join(clean) if clean else 'none'}")
    return 1 if fails else 0

if __name__=="__main__":
    sys.exit(main())
