# SavePilot

[![macOS app](https://github.com/sambringsluck/SavePilot/actions/workflows/macos-app.yml/badge.svg)](https://github.com/sambringsluck/SavePilot/actions/workflows/macos-app.yml)
[![Cross-platform core](https://github.com/sambringsluck/SavePilot/actions/workflows/cross-platform.yml/badge.svg)](https://github.com/sambringsluck/SavePilot/actions/workflows/cross-platform.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

SavePilot 是一个本地优先的智能保存与文件归类工具：它监测新文件写入，理解文件内容和你已有的目录结构，给出存放与命名建议；只有你确认后才会创建目录、移动或重命名。macOS 提供原生 SwiftUI 应用；Windows、Linux 及 macOS 也可使用 `CrossPlatform/` 中的 Python GUI/CLI。

> 当前是开发者预览版。核心整理流程、权限检测、安全移动与回归测试已可用；面向普通消费者的 macOS 免警告安装包仍需要 Apple Developer ID 签名与公证。

## 快速体验 macOS

系统要求：macOS 14+，并安装 Xcode Command Line Tools。

```bash
git clone https://github.com/sambringsluck/SavePilot.git
cd SavePilot
zsh Scripts/run-self-test.sh
zsh Scripts/build-app.sh release
open dist/SavePilot.app
```

第一次打开会显示三个默认值：监听桌面与下载、归档到文稿、所有移动必须确认。建议先在设置中选择一个专门的测试归档目录，再放入几份无关紧要的测试文件。辅助功能仅用于识别标准“保存/另存为”面板，不影响落盘后的目录监测。

## Windows / Linux

跨平台版需要 Python 3.10+，提供本地文件夹索引、稳定文件监测、Tk 确认界面、OpenXML 解析，以及可选 PDF/OCR 增强：

```bash
cd CrossPlatform
# Linux
sh installers/install-linux.sh
# Windows PowerShell
.\installers\install-windows.ps1
```

安装后运行 `savepilot doctor`，然后用 `savepilot-gui --watch <下载目录> --root <归档根目录>` 启动确认队列。详见 [`CrossPlatform/README.md`](CrossPlatform/README.md) 和 [`Docs/PORTABILITY.md`](Docs/PORTABILITY.md)。

## 使用流程

1. 保存面板出现时，SavePilot 可根据文件名和来源应用先给出初步路径；复制路径后可在系统保存面板按 `⌘⇧G` 快速跳转。
2. 文件写完后，递归文件系统监测会等待大小和修改时间稳定，再读取真实内容进行复核。
3. 启动后会主动发现 Desktop 与 Downloads 顶层已有的积压文件，先分析最近的一小批；“扫描全部现有文件”可一次加入更多文件。
4. 它优先检索配置的归档根目录，以及桌面/下载中已有文件夹的名称、文件名与格式画像；通用根目录本身不会伪装成“高匹配目录”。学习文件会进一步识别物理、数学、经济学等可复用学科；证据不足时才回退到“学习”。没有可靠匹配时，只有文件名或正文提供充分证据，或者相似主题已在 3 个不同文件中重复出现，才会建议新建稳定的主题目录；不会使用单个文件标题创建一文件一目录，且仍需用户确认。
5. 对 `hw3.pdf`、`Untitled.docx`、`scan001.pdf` 等低信息量名称，落盘后会结合正文给出可编辑的命名建议，并强制保留扩展名。例如 `hw3.pdf` 的正文是 AP Physics C 力学作业时，可建议 `AP物理C_力学_作业3.pdf`。用户接受或修改后的命名风格会作为本地个人训练数据。
6. 左侧建议队列可任意点选，不必按顺序处理。推荐路径和文件名均可直接修改；不存在的目标目录只会在确认后创建。你也可以使用目录选择器、保留原位或确认建议；移动和重命名支持撤销且绝不覆盖同名文件。

## 文件夹主题审计

选择“检查文件夹归类…”后，SavePilot 会分析所选文件夹顶层最多 160 个普通文件和子文件夹，用本机分词与 TF-IDF 主题向量建立多数主题画像。子文件夹会递归抽取少量、格式多样的代表文件，并独立比较“父目录声明用途”与“子目录实际主题”。只有明显偏离的少数项目才会进入推荐列表，并获得一个排除原文件夹后的新存放路径。至少需要 5 个可分析项目；应用不会自动移动任何审计结果。

如果某个候选子文件夹本身内容匹配、只是上级目录放错，SavePilot 会保留这个候选并先生成一条“迁移整个文件夹”的独立建议，而不是直接拒绝路径。依赖文件会直接显示迁移后的正确目标；在文件夹建议确认或拒绝前，其确认按钮暂时停用。文件夹实际落地后（包括重名后缀），依赖文件路径会自动同步；若拒绝迁移，则回退到候选文件夹当前位置。

## 智能分析能力

- 文本与源码：按内容、文件名、UTType、语言和实体分析；Markdown 会剥离语法、YAML 头部及对话导出中的思考/工具调用记录，避免机器日志淹没正文。
- PDF：优先读取开头、正文中段和结尾的代表页，而不是只看前几页；扫描页使用 Apple Vision OCR。
- 图片：OCR、图像分类、条码/二维码、人脸数量及基础 EXIF 信息。
- DOCX、PPTX、XLSX：直接解析 OpenXML 内容；Pages、其他文档继续使用 Spotlight 与 Quick Look 兜底。
- 音视频：读取时长和 AVFoundation 元数据。
- ZIP/TAR/GZ：读取归档目录清单，不解压到磁盘。
- 其他任意格式：至少使用 UTType、文件魔数、文件名、系统元数据和 Quick Look 预览进行判断。
- 分类：内置双语关键词与 Natural Language 语义向量；自动模式在兼容系统上可使用 Apple Foundation Models；也可连接本机 Ollama。
- 层级学科识别：当前文件有充分证据时，从“学习”下继续区分物理、数学、统计、经济学、计算机、化学、生物、历史和语言；个人画像只可以打破接近平局，不能凭空推断学科。
- 内容感知命名：从学科、课程、单元、文档类型与作业编号组成可检索文件名；仅对低信息量原名主动建议，且需要人工确认。
- 个性化：从已有文件夹按“近期 + 历史跨度 + 格式多样性”抽样读取真实文件内容（不只看文件名）；主题不一致时自动扩展到最多 24 个文件，并以多数文件的主主题簇抑制离群项。每个文件同时形成连接目录、实体、关键词与格式的本地超边。最终通过正文主题、共享实体/关键词、文件名/目录名和格式习惯四路排序融合，并同时检查绝对证据、第一第二名差距和文件夹一致度；证据不足或候选接近时主动保留原位。索引使用对数词频抑制模板、日志及 JSON 重复字段的干扰，并同时覆盖常用大目录和近期建立的小目录。
- 文件关系图：跨 Desktop、Downloads 和归档根目录比较已整理与未整理文件；目录位置只是可纠正标签。启动时会按入口均衡、近期与历史跨度混合预读 160–240 个文件，而不是固定只取最近 80 个。同主题文件可先形成项目簇再共同选目录，词面相似但用途不同的文件形成困难负例并受到用途门控。
- 准确性保护：个人记忆按“目标目录 + 文件格式 + 内容主题”分别聚类，不会把同一目录中互不相关的主题合并成一条规则；明确拒绝会抑制相似建议。低一致度的混合项目目录不能只因为某一个参考文件相似而吸收新文件；带“提交/申报/竞赛”用途的项目目录及子目录必须在当前文件中找到项目锚点。同格式不再构成强证据；`images`、`data`、`output` 等项目内部通用目录必须有项目上下文才能被选中。已有个人记忆或本地 RAG 结论不会被只看到精简提示的大模型覆盖。
- 批次一致性：对名称相同、末尾编号不同的截图、扫描页和导出页，只有至少 4 个文件中出现 3 个以上高质量证据且 70% 指向同一项目时，才会统一项目路径，避免逐页 OCR 波动造成分散归类。

“支持所有格式”指任何普通文件都能被发现、获得元数据级建议并进入人工确认流程。加密文件、损坏文件或没有 Quick Look/Spotlight 支持的私有格式，无法保证提取其内部语义，但仍会基于格式、文件名及目录上下文推荐。

## 安装与首次设置

系统要求：macOS 14 或更高版本。

1. 打开 `dist/SavePilot.app`，在菜单栏找到 SavePilot 图标。
2. 在“设置”中选择监听目录与归档根目录。默认监听下载和桌面；也可选择“监听所有个人文件”。该模式永久排除 `~/Library`、隐藏目录、应用包、Photos/Music/TV 等受管理资料库内部文件、废纸篓和开发构建缓存。
3. 若要识别其他应用的系统保存面板，点击“辅助功能 → 授权”。
4. “完全磁盘访问”是可选项，仅在你主动加入受保护目录或 macOS 拒绝已选目录时需要。
5. 可选择登录时自动启动。先用一个无关紧要的测试文件验证你的目录设置。

macOS 的权限必须由用户在系统设置中明确批准，应用不会也不能绕过该机制。应用使用本地临时签名；如果重新构建，系统可能把它视为新版本并要求重新授权。

隐私说明见 [`PRIVACY.md`](PRIVACY.md)，安全报告方式见 [`SECURITY.md`](SECURITY.md)。

## 智能引擎模式

- **自动**：优先尝试 Apple Foundation Models；不可用时使用内置语义引擎。若本机已有 Ollama embedding 模型，也会在稀疏检索证据不足时用它召回候选，再交给目录主题、关系图、层级冲突和置信度门控复核。
- **Apple 本机模型**：显式使用兼容系统上的 Apple Foundation Models，失败后安全回退。
- **Ollama**：只连接 `127.0.0.1:11434`。高准确率配置使用 `qwen3-embedding:4b` 做批量语义召回、`qwen3:4b` 只重排最接近的少量候选；embedding 不会单独批准移动。两者各约 2.5 GB，建议预留约 6 GB 模型空间；未安装或服务离线时自动安全降级，不阻断保存流程。
- **DeepSeek API**：可选云端增强，默认模型 `deepseek-flash`。密钥只保存在 macOS 钥匙串；默认仅发送文件名、类型、实体、目录末级名称和裁剪后的摘要，不上传原文件。
- **内置本地引擎**：完全离线、无额外依赖。

Apple、Vision、Natural Language、Spotlight 与 Quick Look 路径都在本机执行；Ollama 模式也被限制为本机回环地址。只有主动选择 DeepSeek API 时才会联网，且可选择是否发送最多 4,000 字符的详细内容。

推荐的本地高准确率配置：

```bash
ollama pull qwen3-embedding:4b
ollama pull qwen3:4b
```

## 为什么不能真正改写每个应用的保存窗口

保存面板属于发起保存的应用，macOS 没有受支持的系统扩展点允许第三方安全地向所有应用的保存面板注入自定义控件。某些应用还使用自绘窗口、沙盒容器或自己的云端保存流程。

SavePilot 使用两层方案：辅助功能只读识别保存窗口并提供落盘前提示；FSEvents 在落盘后读取真实文件并给出最终建议。这覆盖通用“保存/另存为/下载”流程，同时不替其他应用点击按钮，也不读取密码框。

## 从源码构建与测试

需要 Swift 6 / Xcode Command Line Tools：

```bash
chmod +x Scripts/build-app.sh Scripts/run-self-test.sh Scripts/run-oracle-eval.sh
zsh Scripts/run-oracle-eval.sh
zsh Scripts/run-oracle-v2-eval.sh
PYTHONPATH=CrossPlatform/src python3 Training/hard_case_corpus.py
PYTHONPATH=CrossPlatform/src python3 Training/evaluate_hard_cases.py Training/generated/savepilot-hard-cases-v2.jsonl
PYTHONPATH=CrossPlatform/src python3 Training/train_embedding_relation.py Training/generated/savepilot-hard-cases-v2.jsonl
./Scripts/run-self-test.sh
./Scripts/build-app.sh
open dist/SavePilot.app
```

## 安全原则

- 默认只读分析；只有人工确认才创建目录或移动文件。
- 永不覆盖同名文件，冲突时自动添加序号。
- 撤销时若原位置出现同名文件，会停止而不是覆盖。
- 忽略系统缓存、浏览器/开发工具 profile、`~/Documents/Codex` 工作区、废纸篓、应用容器和常见临时文件，避免用噪声污染个人训练记忆。
- AI 返回的目录选择和新文件夹名会经过边界检查；不能把文件移出用户配置的归档根目录。
- 移动历史和学习规则保存在本机 UserDefaults 中。
- 确认、路径纠正和拒绝会形成结构化的本地个人训练样本（最多保留最近 2,000 条）；内容不会因学习功能上传云端，清除学习规则会一并删除样本。

## 项目结构

- `ContentExtractor.swift` / `AdvancedExtractors.swift`：多格式内容理解、OCR 与系统兜底。
- `FolderMonitor.swift`：递归 FSEvents 监测与写入稳定性判断。
- `SystemIntegration.swift`：保存面板只读识别与权限入口。
- `SuggestionEngine.swift` / `AppleFoundationRecommender.swift` / `OllamaRecommender.swift`：多级推荐引擎。
- `DeepSeekRecommender.swift` / `KeychainStore.swift`：可选云端分类与钥匙串密钥管理。
- `LearningStore.swift`：本机 RAG 式个人记忆、按主题分簇的正负反馈学习与新主题聚类门槛。
- `AcademicSubjectClassifier.swift` / `UserProfileStore.swift` / `FileNameSuggester.swift`：学科层级、渐进式个人画像与内容感知命名。
- `FolderKnowledgeIndex.swift` / `EvidenceRanker.swift`：自适应抽样真实内容，构建可增量更新的本地混合 RAG、知识图谱/超图主题索引，并执行多路排序融合与低置信度拒绝。
- `SeriesConsensus.swift`：对编号批次文件执行保守的项目级一致性校准。
- `DocumentRelationshipEngine.swift`：建立跨目录文件关系、识别可复用项目簇，并阻断困难混淆对。
- `FileMover.swift`：确认移动、冲突保护和撤销。

产品边界、评估方法和路线图见 [`Docs/PRD.md`](Docs/PRD.md)；困难样本、文件关系图与模型/API 取舍见 [`Docs/ACCURACY.md`](Docs/ACCURACY.md)。基础合成 Oracle 回归可用 `zsh Scripts/run-oracle-eval.sh`；全新且独立的对抗测试集可用 `zsh Scripts/run-oracle-v2-eval.sh`，它另外覆盖错文件名、OCR 噪声、发布顺序、关系硬负例和父子目录图。两者用于防止规则回退，不等同于真实个人文件的准确率。
