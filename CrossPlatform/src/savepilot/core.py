from __future__ import annotations

import html
import json
import logging
import math
import mimetypes
import os
import platform
import re
import shutil
import zipfile
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

logging.getLogger("pypdf").setLevel(logging.ERROR)


TEXT_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".jsonl", ".yaml", ".yml",
    ".toml", ".xml", ".html", ".htm", ".css", ".js", ".jsx", ".ts", ".tsx", ".swift",
    ".py", ".rb", ".go", ".rs", ".java", ".kt", ".c", ".h", ".cpp", ".hpp", ".cs",
    ".php", ".sh", ".zsh", ".fish", ".sql", ".log", ".ini", ".conf", ".tex", ".rtf",
}
PROFILE_EXTENSIONS = TEXT_EXTENSIONS | {".pdf", ".docx", ".pptx", ".xlsx"}

STOP_WORDS = {
    "the", "and", "for", "with", "from", "that", "this", "are", "was", "were", "have", "has",
    "into", "file", "document", "page", "http", "https", "com", "www", "model", "article",
    "chapter", "section", "part", "version", "content", "type", "role", "message", "response",
    "export", "scan", "scanned", "img", "image",
    "author", "unknown", "final", "draft", "copyright", "footer", "header", "generated",
    "of", "to", "in", "is", "it", "as", "an", "be", "by", "on", "or", "not", "you", "your",
    "do", "like", "will", "can", "may", "we", "our", "they", "their", "which", "what", "when",
    "where", "who", "how", "why", "also", "than", "then", "all", "any", "each", "other", "more",
    "most", "some", "such", "only", "same", "too", "very", "after", "before", "because", "about",
    "between", "through", "during", "under", "over", "again", "once", "first", "later", "however",
    "therefore", "thus", "still", "even", "much", "many", "make", "makes", "made", "give", "gives",
    "show", "shows", "use", "used", "using", "try", "believe", "think", "know", "learn", "read",
    "reading", "way", "ways", "people", "person", "information", "claim", "claims", "answer",
    "conversation", "user", "assistant", "situation", "method", "tools", "new", "bad", "wrong", "correct", "simple",
    "common", "times", "piece", "behind", "quite", "的", "了", "和", "与", "及", "是", "在", "为",
    "对", "将", "中", "有", "一个", "文件", "文档", "内容", "什么", "为什么", "不同", "重要", "问题",
    "可以", "这个", "没有", "进行", "以及", "通过", "需要",
}

SUBJECTS = {
    "物理": (["physics", "ap physics", "物理"], ["mechanics", "force", "motion", "energy", "momentum", "gauss", "flux", "electric", "magnetism", "力学", "电磁", "动量"]),
    "数学": (["mathematics", "math", "数学", "calculus", "微积分"], ["algebra", "geometry", "derivative", "integral", "theorem", "matrix", "vector", "代数", "几何", "导数", "积分", "矩阵"]),
    "统计": (["statistics", "statistical", "统计学", "统计"], ["probability", "regression", "distribution", "hypothesis", "variance", "bayes", "概率", "回归", "分布", "方差"]),
    "经济学": (["economics", "microeconomics", "macroeconomics", "经济学", "微观经济", "宏观经济"], ["market", "supply", "demand", "utility", "inflation", "gdp", "elasticity", "equilibrium", "市场", "供给", "需求", "效用", "均衡"]),
    "计算机": (["computer science", "computing", "计算机科学", "计算机"], ["algorithm", "data structure", "programming", "database", "network", "machine learning", "算法", "数据结构", "编程", "数据库"]),
    "化学": (["chemistry", "化学"], ["molecule", "reaction", "organic", "compound", "acid", "base", "分子", "反应", "有机", "化合物", "酸碱"]),
    "生物": (["biology", "biological", "生物学", "生物"], ["cell", "genetics", "evolution", "ecology", "dna", "protein", "细胞", "遗传", "进化", "生态"]),
    "历史": (["history", "historical", "world history", "global history", "历史", "世界史", "通史"], ["civilization", "empire", "ancient", "medieval", "revolution", "dynasty", "文明", "帝国", "古代", "革命", "王朝"]),
    "语言": (["language", "lang", "linguistics", "english", "chinese", "语言", "英语", "语文"], ["grammar", "vocabulary", "reading", "writing", "literature", "syntax", "语法", "词汇", "阅读", "写作"]),
}

GENERAL_CATEGORIES = {
    "工作": ["interview", "resume", "meeting", "proposal", "client", "面试", "简历", "会议", "客户"],
    "财务": ["finance", "invoice", "portfolio", "investment", "bank", "tax", "金融", "投资", "发票", "银行"],
    "合同与法律": ["contract", "agreement", "legal", "signature", "合同", "协议", "法律", "签署"],
    "医疗": ["medical", "diagnosis", "patient", "hospital", "医疗", "诊断", "患者", "医院"],
    "旅行": ["travel", "flight", "hotel", "itinerary", "旅行", "航班", "酒店", "行程"],
    "代码": ["source code", "algorithm", "repository", "function", "class", "代码", "算法", "函数"],
}

RELATIONSHIP_SIGNATURES = [
    (
        "数学建模进阶课",
        [
            ["投资组合", "资产配置", "portfolio", "asset allocation"],
            ["风险", "波动率", "标准差", "risk", "volatility", "standard deviation"],
            ["收益", "回报", "return", "expected return"],
            ["最优", "优化", "约束", "模型", "optimal", "optimization", "constraint", "markowitz"],
            ["股票", "资产", "银行", "stock", "asset", "bank"],
        ],
        4,
    ),
    (
        "IEO经济学竞赛",
        [
            ["ieo", "international economics olympiad", "国际经济学奥林匹克"],
            ["微观经济", "宏观经济", "microeconomics", "macroeconomics"],
            ["题库", "选拔赛", "真题", "problem set", "competition"],
            ["经济学", "economics", "供给", "需求", "supply", "demand"],
        ],
        3,
    ),
]


@dataclass(slots=True)
class ExtractedContent:
    text: str
    kind: str
    summary: str
    signals: list[str]


@dataclass(slots=True)
class FolderProfile:
    path: str
    weights: dict[str, float]
    sampled_files: int
    coherence: float
    extensions: list[str]


@dataclass(slots=True)
class Suggestion:
    source: str
    destination: str
    proposed_file_name: str
    reason: str
    confidence: float
    creates_folder: bool

    @property
    def changes_name(self) -> bool:
        return Path(self.source).name != self.proposed_file_name


@dataclass(slots=True)
class DocumentRelationship:
    score: float
    shared_terms: list[str]
    topic_name: str | None
    evidence: list[str]


def _read_limited(path: Path, limit: int = 512_000) -> str:
    data = path.read_bytes()[:limit]
    for encoding in ("utf-8", "utf-16", "latin-1"):
        try:
            return data.decode(encoding)
        except UnicodeError:
            continue
    return ""


def _strip_markup(value: str) -> str:
    value = re.sub(r"^---\s.*?\s---\s", " ", value, count=1, flags=re.S)
    value = re.sub(r"```.*?```", " ", value, flags=re.S)
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"!\[[^]]*]\([^)]*\)", " ", value)
    value = re.sub(r"\[([^]]+)]\([^)]*\)", r"\1", value)
    return value


def _extract_openxml(path: Path) -> str:
    prefixes = {
        ".docx": ("word/document.xml", "word/header", "word/footer"),
        ".pptx": ("ppt/slides/", "ppt/notesSlides/"),
        ".xlsx": ("xl/sharedStrings.xml", "xl/worksheets/"),
    }.get(path.suffix.lower(), ())
    parts: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if any(name == prefix or name.startswith(prefix) for prefix in prefixes):
                    raw = archive.read(name).decode("utf-8", errors="ignore")
                    parts.append(html.unescape(re.sub(r"<[^>]+>", " ", raw)))
    except (OSError, zipfile.BadZipFile):
        return ""
    return " ".join(parts)


def _extract_pdf(path: Path) -> tuple[str, str]:
    try:
        from pypdf import PdfReader  # type: ignore
    except ImportError:
        return "", "PDF（安装 savepilot[pdf] 后可读取正文）"
    try:
        reader = PdfReader(path)
        count = len(reader.pages)
        indices = sorted({0, 1, count // 4, count // 2, (count * 3) // 4, count - 1})
        text = " ".join((reader.pages[i].extract_text() or "") for i in indices if 0 <= i < count)
        return text, f"PDF / {count} pages"
    except Exception:
        return "", "PDF（读取失败）"


def _extract_image(path: Path) -> tuple[str, list[str]]:
    try:
        from PIL import Image  # type: ignore
        import pytesseract  # type: ignore
        return pytesseract.image_to_string(Image.open(path)), ["Tesseract OCR"]
    except (ImportError, OSError, RuntimeError):
        return "", []


def extract(path: Path) -> ExtractedContent:
    path = path.expanduser().resolve()
    suffix = path.suffix.lower()
    signals: list[str] = []
    kind = mimetypes.guess_type(path.name)[0] or (suffix[1:].upper() if suffix else "unknown")
    text = ""
    try:
        if suffix in TEXT_EXTENSIONS:
            text = _read_limited(path)
            if suffix in {".md", ".markdown", ".html", ".htm"}:
                text = _strip_markup(text)
            signals.append("text")
        elif suffix in {".docx", ".pptx", ".xlsx"}:
            text = _extract_openxml(path)
            signals.append("OpenXML")
        elif suffix == ".pdf":
            text, kind = _extract_pdf(path)
            if text:
                signals.append("PDF text")
        elif suffix in {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"}:
            text, image_signals = _extract_image(path)
            signals.extend(image_signals)
    except OSError:
        pass
    text = re.sub(r"\s+", " ", text).strip()[:20_000]
    if not text:
        text = f"{path.stem} {suffix} {kind}"
        signals.append("metadata fallback")
    return ExtractedContent(text=text, kind=kind, summary=text[:260], signals=signals)


def tokens(text: str) -> list[str]:
    result: list[str] = []
    for raw in re.findall(r"[a-zA-Z][a-zA-Z0-9']+|[\u3400-\u9fff]+", text.lower()):
        if raw in STOP_WORDS:
            continue
        if re.fullmatch(r"[\u3400-\u9fff]+", raw) and len(raw) > 4:
            result.extend(raw[i:i + 2] for i in range(len(raw) - 1))
        elif len(raw) >= 2:
            result.append(raw)
    return result


def _contains(signal: str, evidence: str, token_set: set[str]) -> bool:
    signal = signal.lower()
    return signal in evidence if (" " in signal or re.search(r"[\u3400-\u9fff]", signal)) else signal in token_set


def classify_subject(title: str, body: str) -> tuple[str, float, list[str]] | None:
    title_l, body_l = title.lower(), body.lower()
    title_tokens, body_tokens = set(tokens(title_l)), set(tokens(body_l))
    ranked: list[tuple[str, float, list[str], bool, bool]] = []
    for subject, (aliases, keywords) in SUBJECTS.items():
        score, hits, title_alias, body_alias = 0.0, set(), False, False
        alias_norm = {alias.lower() for alias in aliases}
        for alias in aliases:
            if _contains(alias, title_l, title_tokens):
                score += 5.0; hits.add(alias); title_alias = True
            elif _contains(alias, body_l, body_tokens):
                score += 2.8; hits.add(alias); body_alias = True
        for keyword in keywords:
            if keyword.lower() in alias_norm:
                continue
            if _contains(keyword, title_l, title_tokens) or _contains(keyword, body_l, body_tokens):
                score += 1.8 if _contains(keyword, title_l, title_tokens) else 1.0
                hits.add(keyword)
        ranked.append((subject, score, sorted(hits), title_alias, body_alias))
    ranked.sort(key=lambda item: item[1], reverse=True)
    best, second = ranked[0], ranked[1]
    enough = best[1] >= 4.0 if best[3] else (len(best[2]) >= 2 and best[1] >= 3.8 if best[4] else len(best[2]) >= 3 and best[1] >= 3.0)
    margin = best[1] - second[1]
    if not enough or margin < 1.0:
        return None
    return best[0], min(0.97, 0.58 + best[1] * 0.045 + margin * 0.035), best[2][:8]


def _low_information_name(stem: str) -> bool:
    value = stem.strip().lower()
    return bool(
        re.fullmatch(r"(?:hw|homework|assignment)[ _-]*\d{0,3}", value)
        or re.fullmatch(r"(?:untitled|document|doc|scan|scanned|image|img|download|file)[ _-]*\d{0,6}", value)
        or value.isdigit() or len(value) < 4 or len(value) > 120
    )


def suggest_filename(path: Path, content: ExtractedContent, subject: str | None, separator: str = "_") -> str | None:
    if not _low_information_name(path.stem):
        return None
    evidence = f"{path.stem} {content.summary} {content.text[:4000]}".lower()
    parts: list[str] = []
    if subject:
        parts.append("AP物理C" if subject == "物理" and "ap physics c" in evidence else subject)
        if subject == "物理":
            if any(term in evidence for term in ("mechanics", "mech-", "力学")): parts.append("力学")
            elif any(term in evidence for term in ("electric", "gauss", "电磁")): parts.append("电磁学")
        match = re.search(r"(?:\bhw|homework|作业)[ #_-]*(\d{1,3})", evidence)
        if match: parts.append(f"作业{match.group(1)}")
        elif "homework" in evidence or "作业" in evidence: parts.append("作业")
        elif "textbook" in evidence or "教材" in evidence: parts.append("教材")
        else: parts.append("学习资料")
    else:
        descriptors = [
            ("发票", ["invoice", "amount due", "tax", "发票", "税额", "价税合计"], 2),
            ("收据", ["receipt", "paid", "total", "purchase", "收据", "已付", "小票"], 2),
            ("会议记录", ["meeting minutes", "attendees", "agenda", "action items", "会议纪要", "参会人", "待办"], 2),
            ("面试记录", ["interview", "candidate", "hiring", "resume", "面试", "候选人", "简历"], 2),
            ("合同", ["agreement", "contract", "parties", "signature", "合同", "协议", "签署"], 3),
            ("行程单", ["itinerary", "flight", "hotel", "booking", "行程", "航班", "酒店", "预订"], 3),
        ]
        ranked = sorted(((name, sum(term in evidence for term in terms), minimum) for name, terms, minimum in descriptors), key=lambda x: x[1], reverse=True)
        if not ranked or ranked[0][1] < ranked[0][2] or (len(ranked) > 1 and ranked[0][1] == ranked[1][1]):
            return None
        parts.append(ranked[0][0])
        date = re.search(r"\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})\b", evidence)
        if date: parts.append(f"{date.group(1)}-{int(date.group(2)):02d}-{int(date.group(3)):02d}")
    base = re.sub(r"[\\/:\x00-\x1f]", "_", separator.join(parts)).strip(" .")[:90]
    proposed = base + path.suffix
    return None if proposed.casefold() == path.name.casefold() else proposed


def _vector(counter: Counter[str]) -> dict[str, float]:
    values = {key: 1.0 + math.log(max(1, value)) for key, value in counter.items()}
    norm = math.sqrt(sum(value * value for value in values.values())) or 1.0
    return {key: value / norm for key, value in values.items()}


def _cosine(lhs: dict[str, float], rhs: dict[str, float]) -> float:
    small, large = (lhs, rhs) if len(lhs) <= len(rhs) else (rhs, lhs)
    return sum(value * large.get(key, 0.0) for key, value in small.items())


def document_relationship(
    left_name: str,
    left_text: str,
    right_name: str,
    right_text: str,
) -> DocumentRelationship | None:
    """Compare files without trusting their current directory labels.

    Structured topic signatures are allowed to connect a pair. Generic lexical
    similarity is returned for graph construction, but callers should require a
    component of at least three files before moving anything on that evidence.
    """
    left = f"{Path(left_name).stem} {left_text}".casefold()
    right = f"{Path(right_name).stem} {right_text}".casefold()
    for topic, groups, minimum in RELATIONSHIP_SIGNATURES:
        left_groups = {index for index, group in enumerate(groups) if any(term.casefold() in left for term in group)}
        right_groups = {index for index, group in enumerate(groups) if any(term.casefold() in right for term in group)}
        shared_groups = left_groups & right_groups
        if len(left_groups) >= minimum and len(right_groups) >= minimum and len(shared_groups) >= minimum:
            evidence = [next((term for term in groups[index] if term.casefold() in left and term.casefold() in right), groups[index][0]) for index in sorted(shared_groups)]
            return DocumentRelationship(min(.97, .76 + len(shared_groups) * .04), evidence[:8], topic, ["structured topic signature", "cross-folder content relation"])

    left_counts, right_counts = Counter(tokens(left)), Counter(tokens(right))
    shared = set(left_counts) & set(right_counts)
    if len(shared) < 4: return None
    containment = len(shared) / max(1, min(len(left_counts), len(right_counts)))
    jaccard = len(shared) / max(1, len(set(left_counts) | set(right_counts)))
    cosine = _cosine(_vector(left_counts), _vector(right_counts))
    score = cosine * .50 + containment * .34 + jaccard * .16
    if score < .34: return None
    ranked = sorted(shared, key=lambda term: left_counts[term] + right_counts[term], reverse=True)
    return DocumentRelationship(min(.90, score), ranked[:8], None, ["content terms", "file-level cosine similarity"])


def build_profile(folder: Path, limit: int = 18) -> FolderProfile | None:
    try:
        files = [item for item in folder.iterdir() if item.is_file() and item.suffix.lower() in PROFILE_EXTENSIONS and item.stat().st_size <= 80_000_000]
    except OSError:
        return None
    files.sort(key=lambda item: item.stat().st_mtime, reverse=True)
    files = files[:limit]
    if not files:
        return None
    counters = [Counter(tokens(f"{path.stem} {extract(path).text[:8000]}")) for path in files]
    vectors = [_vector(counter) for counter in counters]
    if len(vectors) == 1:
        dominant, coherence = [0], 1.0
    else:
        medoid = max(range(len(vectors)), key=lambda i: sum(_cosine(vectors[i], other) for other in vectors))
        similarities = [_cosine(vector, vectors[medoid]) for vector in vectors]
        dominant_count = max(2, math.ceil(len(vectors) * 0.6))
        dominant = sorted(range(len(vectors)), key=lambda i: similarities[i], reverse=True)[:dominant_count]
        pairs = [_cosine(vectors[a], vectors[b]) for pos, a in enumerate(dominant) for b in dominant[pos + 1:]]
        coherence = sum(pairs) / len(pairs) if pairs else 1.0
    combined = Counter(tokens(folder.name))
    for index in dominant: combined.update(counters[index])
    weights = _vector(Counter(dict(combined.most_common(360))))
    return FolderProfile(str(folder.resolve()), weights, len(files), coherence, sorted({p.suffix.lower() for p in files}))


def discover_profiles(roots: Iterable[Path], depth: int = 2) -> list[FolderProfile]:
    profiles: list[FolderProfile] = []
    seen: set[Path] = set()
    for raw_root in roots:
        root = raw_root.expanduser().resolve()
        if not root.is_dir(): continue
        candidates = [root]
        for current, directories, _ in os.walk(root):
            current_path = Path(current)
            level = len(current_path.relative_to(root).parts)
            directories[:] = [name for name in directories if not name.startswith(".") and name not in {"node_modules", ".git", "Library"}]
            if level >= depth: directories[:] = []
            candidates.extend(current_path / name for name in directories)
        for folder in candidates:
            if folder in seen: continue
            seen.add(folder)
            profile = build_profile(folder)
            if profile: profiles.append(profile)
    return profiles


def data_directory() -> Path:
    if os.name == "nt":
        base = Path(os.getenv("APPDATA", Path.home() / "AppData/Roaming"))
    elif platform.system() == "Darwin":
        base = Path.home() / "Library/Application Support"
    else:
        base = Path(os.getenv("XDG_DATA_HOME", Path.home() / ".local/share"))
    return base / "SavePilot"


def save_profiles(profiles: list[FolderProfile]) -> Path:
    target = data_directory() / "cross-platform-index-v1.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps([asdict(profile) for profile in profiles], ensure_ascii=False, indent=2), encoding="utf-8")
    return target


def load_profiles() -> list[FolderProfile]:
    target = data_directory() / "cross-platform-index-v1.json"
    try:
        return [FolderProfile(**item) for item in json.loads(target.read_text(encoding="utf-8")) if Path(item["path"]).is_dir()]
    except (OSError, ValueError, TypeError, KeyError):
        return []


def _protected_anchor(folder_name: str) -> str | None:
    markers = ("提交", "申报", "申请", "参赛", "竞赛", "比赛", "award", "submission", "application")
    lowered = folder_name.casefold()
    if not any(marker in lowered for marker in markers): return None
    for marker in markers: lowered = lowered.replace(marker, " ")
    lowered = re.sub(r"\d{3,8}|[_\-\s]+", " ", lowered).strip()
    return lowered if len(lowered) >= 2 else None


def _intent_compatible(profile: FolderProfile, profiles: list[FolderProfile], query_text: str) -> bool:
    path = Path(profile.path)
    for container in profiles:
        parent = Path(container.path)
        try: path.relative_to(parent)
        except ValueError: continue
        anchor = _protected_anchor(parent.name)
        if anchor and anchor not in query_text.casefold(): return False
    return True


def recommend(path: Path, roots: list[Path], profiles: list[FolderProfile] | None = None) -> Suggestion:
    path = path.expanduser().resolve()
    content = extract(path)
    subject_match = classify_subject(path.stem, content.text)
    subject = subject_match[0] if subject_match else None
    confidence = subject_match[1] if subject_match else 0.0
    profile_list = profiles if profiles is not None else load_profiles()
    if not profile_list:
        profile_list = discover_profiles(roots)
    destination: Path | None = None
    reason = ""
    creates_folder = False

    if subject:
        aliases = {subject.casefold(), *(alias.casefold() for alias in SUBJECTS[subject][0])}
        destination = next((Path(profile.path) for profile in profile_list if Path(profile.path).name.casefold() in aliases), None)
        if destination:
            reason = f"层级学科识别为“学习 › {subject}”，并匹配已有目录"
        else:
            destination = roots[0].expanduser().resolve() / subject
            creates_folder = not destination.exists()
            reason = f"层级学科识别为“学习 › {subject}”"
    else:
        query_counter = Counter(tokens(f"{path.stem} {content.text[:10000]}"))
        query_vector = _vector(query_counter)
        scored: list[tuple[float, FolderProfile]] = []
        for profile in profile_list:
            if Path(profile.path) == path.parent or not _intent_compatible(profile, profile_list, content.text + " " + path.stem): continue
            if profile.sampled_files < 2 or profile.coherence < 0.18: continue
            semantic = _cosine(query_vector, profile.weights)
            path_terms = set(tokens(Path(profile.path).name))
            overlap = len(set(tokens(path.stem)) & path_terms)
            score = semantic * (0.72 + min(0.28, profile.coherence * 0.28)) + min(0.18, overlap * 0.09)
            scored.append((score, profile))
        scored.sort(key=lambda item: item[0], reverse=True)
        if scored and scored[0][0] >= 0.20 and scored[0][0] - (scored[1][0] if len(scored) > 1 else 0) >= 0.05:
            destination = Path(scored[0][1].path)
            confidence = min(0.94, 0.56 + scored[0][0] * 0.8)
            reason = "对比式内容检索、目录一致度与用途门控一致指向该目录"
        else:
            category_scores = [(name, sum(term in content.text.casefold() or term in path.stem.casefold() for term in terms)) for name, terms in GENERAL_CATEGORIES.items()]
            category_scores.sort(key=lambda item: item[1], reverse=True)
            if category_scores and category_scores[0][1] >= 2 and (len(category_scores) == 1 or category_scores[0][1] > category_scores[1][1]):
                destination = roots[0].expanduser().resolve() / category_scores[0][0]
                creates_folder = not destination.exists()
                confidence = 0.68
                reason = f"正文中多个独立证据指向“{category_scores[0][0]}”"
            else:
                destination = path.parent
                confidence = 0.45
                reason = "证据不足或候选太接近，建议保留原位"
    proposed = suggest_filename(path, content, subject) or path.name
    return Suggestion(str(path), str(destination), proposed, reason, confidence, creates_folder)


def collision_safe_destination(folder: Path, name: str) -> Path:
    candidate = folder / name
    index = 2
    while candidate.exists():
        candidate = folder / f"{Path(name).stem} {index}{Path(name).suffix}"
        index += 1
    return candidate


def confirm_move(suggestion: Suggestion, destination: Path | None = None, file_name: str | None = None) -> Path:
    source = Path(suggestion.source).resolve()
    folder = (destination or Path(suggestion.destination)).expanduser().resolve()
    folder.mkdir(parents=True, exist_ok=True)
    name = Path(file_name or suggestion.proposed_file_name).name
    if source.suffix and Path(name).suffix.casefold() != source.suffix.casefold():
        name = f"{Path(name).stem}{source.suffix}"
    requested = folder / name
    if source == requested: return source
    target = collision_safe_destination(folder, name)
    return Path(shutil.move(str(source), str(target)))
