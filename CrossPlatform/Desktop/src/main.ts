import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { watch, type UnwatchFn } from "@tauri-apps/plugin-fs";
import { isEnabled, enable, disable } from "@tauri-apps/plugin-autostart";
import { isPermissionGranted, requestPermission, sendNotification } from "@tauri-apps/plugin-notification";
import { openUrl } from "@tauri-apps/plugin-opener";
import { load } from "@tauri-apps/plugin-store";
import "./styles.css";

type Suggestion = {
  source: string;
  destination: string;
  proposed_file_name: string;
  reason: string;
  confidence: number;
  creates_folder: boolean;
  changes_name: boolean;
  actionable: boolean;
  summary: string;
  signals: string[];
};

type Settings = {
  watched: string[];
  roots: string[];
  launchAtLogin: boolean;
  completedWelcome: boolean;
};

type Doctor = {
  version: string;
  pdf: boolean;
  ocr: boolean;
  ollama: { available: boolean; models: string[] };
};

type UpdateInfo = {
  current_version: string;
  version: string;
  title: string;
  notes: string;
  download_url: string;
  release_url: string;
};

const defaultSettings: Settings = {
  watched: [],
  roots: [],
  launchAtLogin: false,
  completedWelcome: false,
};

const inTauri = "__TAURI_INTERNALS__" in window;
const browserMemory = new Map<string, unknown>();
const store = inTauri ? await load("settings.json", { autoSave: 150 }) : {
  async get<T>(key: string): Promise<T | undefined> { return browserMemory.get(key) as T | undefined; },
  async set(key: string, value: unknown): Promise<void> { browserMemory.set(key, value); },
  async save(): Promise<void> {},
};
let settings = { ...defaultSettings, ...await store.get<Settings>("settings") };
let suggestions: Suggestion[] = [];
let selectedSource = "";
let unwatchers: UnwatchFn[] = [];
let doctor: Doctor | null = null;
let availableUpdate: UpdateInfo | null = null;
let checkingUpdate = false;
let scanning = false;
let folderPathSuggestions: string[] = [];
let pathSearchTimer: number | undefined;
let pathSearchSequence = 0;
const pendingPaths = new Map<string, number>();

const app = document.querySelector<HTMLDivElement>("#app")!;

function escapeHtml(value: string): string {
  return value.replace(/[&<>'"]/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;",
  })[character]!);
}

function basename(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).at(-1) ?? path;
}

function dirname(path: string): string {
  const pieces = path.split(/[\\/]/);
  pieces.pop();
  return pieces.join(path.includes("\\") ? "\\" : "/") || path;
}

async function saveSettings(): Promise<void> {
  await store.set("settings", settings);
  await store.save();
}

async function warmFolderPathIndex(): Promise<void> {
  if (!inTauri) return;
  const roots = [...new Set([...settings.roots, ...settings.watched])];
  await invoke<number>("warm_folder_index", { roots }).catch(() => 0);
}

async function chooseFolder(target: "watch" | "root"): Promise<void> {
  const selected = inTauri
    ? await open({ directory: true, multiple: false, title: target === "watch" ? "选择监听文件夹" : "选择归档根目录" })
    : window.prompt(target === "watch" ? "输入监听文件夹（浏览器预览）" : "输入归档根目录（浏览器预览）");
  if (typeof selected !== "string") return;
  const list = target === "watch" ? settings.watched : settings.roots;
  if (!list.includes(selected)) list.push(selected);
  await saveSettings();
  render();
  void warmFolderPathIndex();
}

async function completeWelcome(): Promise<void> {
  if (!settings.watched.length || !settings.roots.length) return;
  settings.completedWelcome = true;
  await saveSettings();
  await startWatchers();
  render();
  void warmFolderPathIndex();
  await scanExisting();
}

async function analyzePath(path: string): Promise<void> {
  if (!settings.roots.length || suggestions.some(item => item.source === path)) return;
  try {
    const suggestion = await invoke<Suggestion>("analyze_file", { path, roots: settings.roots });
    if (!suggestion.actionable) return;
    suggestions = [suggestion, ...suggestions.filter(item => item.source !== path)];
    selectedSource ||= suggestion.source;
    render();
    let allowed = await isPermissionGranted();
    if (!allowed) allowed = (await requestPermission()) === "granted";
    if (allowed) sendNotification({ title: "SavePilot 有一条新建议", body: `${basename(path)} → ${basename(suggestion.destination)}` });
  } catch {
    // Temporary files and incomplete downloads are expected to disappear while being observed.
  }
}

function scheduleAnalyze(path: string): void {
  window.clearTimeout(pendingPaths.get(path));
  pendingPaths.set(path, window.setTimeout(() => {
    pendingPaths.delete(path);
    void analyzePath(path);
  }, 1200));
}

async function startWatchers(): Promise<void> {
  for (const stop of unwatchers) stop();
  unwatchers = [];
  for (const folder of settings.watched) {
    try {
      const stop = await watch(folder, event => {
        for (const path of event.paths) scheduleAnalyze(path);
      }, { recursive: false, delayMs: 700 });
      unwatchers.push(stop);
    } catch {
      // The folder can be disconnected; settings keeps it so the user can repair it.
    }
  }
}

async function scanExisting(): Promise<void> {
  if (scanning || !settings.watched.length || !settings.roots.length) return;
  scanning = true;
  render();
  try {
    suggestions = await invoke<Suggestion[]>("scan_existing", {
      watched: settings.watched,
      roots: settings.roots,
      limit: 120,
    });
    selectedSource = suggestions[0]?.source ?? "";
  } finally {
    scanning = false;
    render();
  }
}

async function rebuildIndex(): Promise<void> {
  scanning = true;
  render();
  try {
    const result = await invoke<{ folders: number }>("rebuild_index", { roots: settings.roots });
    await warmFolderPathIndex();
    alert(`已更新 ${result.folders} 个文件夹主题`);
  } finally {
    scanning = false;
    render();
  }
}

async function confirmSelected(): Promise<void> {
  const suggestion = suggestions.find(item => item.source === selectedSource);
  if (!suggestion) return;
  const destination = (document.querySelector<HTMLInputElement>("#destination")?.value ?? "").trim();
  const name = (document.querySelector<HTMLInputElement>("#filename")?.value ?? "").trim();
  if (!destination || !name) return;
  const result = await invoke<{ destination: string }>("confirm_suggestion", {
    source: suggestion.source,
    destination,
    name,
  });
  suggestions = suggestions.filter(item => item.source !== suggestion.source);
  selectedSource = suggestions[0]?.source ?? "";
  render();
  alert(`已存放到：\n${result.destination}`);
}

function dismissSelected(): void {
  suggestions = suggestions.filter(item => item.source !== selectedSource);
  selectedSource = suggestions[0]?.source ?? "";
  render();
}

async function refreshDoctor(): Promise<void> {
  try {
    doctor = await invoke<Doctor>("engine_doctor");
  } catch {
    doctor = null;
  }
  render();
}

async function checkForUpdate(manual = false): Promise<void> {
  if (checkingUpdate || !inTauri) return;
  checkingUpdate = true;
  let succeeded = false;
  try {
    availableUpdate = await invoke<UpdateInfo | null>("check_for_update");
    succeeded = true;
  } catch {
    if (manual) alert("暂时无法检查更新，请稍后重试");
  } finally {
    checkingUpdate = false;
    render();
    if (manual && succeeded) {
      if (availableUpdate) (document.querySelector("#update-dialog") as HTMLDialogElement)?.showModal();
      else alert("当前已经是最新版本");
    }
  }
}

async function downloadUpdate(): Promise<void> {
  if (!availableUpdate) return;
  await openUrl(availableUpdate.download_url);
}

async function toggleAutostart(checked: boolean): Promise<void> {
  checked ? await enable() : await disable();
  settings.launchAtLogin = await isEnabled();
  await saveSettings();
  render();
}

function welcomeView(): string {
  const watched = settings.watched.map(path => `<span class="path-chip">${escapeHtml(path)}<button data-remove-watch="${escapeHtml(path)}">×</button></span>`).join("");
  const roots = settings.roots.map(path => `<span class="path-chip">${escapeHtml(path)}<button data-remove-root="${escapeHtml(path)}">×</button></span>`).join("");
  return `<main class="welcome">
    <div class="brand-mark" aria-hidden="true"><span></span></div>
    <p class="eyebrow">WELCOME TO SAVEPILOT</p>
    <h1>让每个文件，一开始就在正确的位置。</h1>
    <p class="lead">SavePilot 在本地理解文件内容，结合你的目录结构提出建议。移动和重命名永远由你确认。</p>
    <section class="setup-card">
      <div><strong>1　监听位置</strong><p>新文件出现的位置，例如“下载”或“桌面”。</p><div class="chips">${watched || "<em>尚未选择</em>"}</div></div>
      <button class="secondary" id="add-watch">选择文件夹</button>
      <div><strong>2　归档范围</strong><p>SavePilot 从这些目录学习你的分类结构。</p><div class="chips">${roots || "<em>尚未选择</em>"}</div></div>
      <button class="secondary" id="add-root">选择文件夹</button>
    </section>
    <button class="primary large" id="start" ${!settings.watched.length || !settings.roots.length ? "disabled" : ""}>开始使用</button>
    <p class="privacy">本地优先 · 不会擅自移动文件 · Ollama 可选</p>
  </main>`;
}

function detailView(suggestion?: Suggestion): string {
  if (!suggestion) return `<section class="empty"><div class="empty-icon">✓</div><h2>暂时没有待处理建议</h2><p>SavePilot 会继续在后台关注你选择的文件夹。</p><button class="secondary" id="scan-empty">扫描现有文件</button></section>`;
  return `<section class="detail">
    <header class="file-header"><div><p class="eyebrow">正在审核</p><h2 title="${escapeHtml(suggestion.source)}">${escapeHtml(basename(suggestion.source))}</h2><p title="${escapeHtml(dirname(suggestion.source))}">${escapeHtml(dirname(suggestion.source))}</p></div><span class="confidence">${Math.round(suggestion.confidence * 100)}%</span></header>
    <div class="card destination-card"><label for="destination">推荐存放位置</label><div class="path-autocomplete"><input id="destination" value="${escapeHtml(suggestion.destination)}" spellcheck="false" autocomplete="off"><div class="path-suggestions" id="path-suggestions"></div></div><p>${suggestion.creates_folder ? "＋ 将新建文件夹　" : ""}${escapeHtml(suggestion.reason)}</p></div>
    <div class="card"><label for="filename">文件名</label><input id="filename" value="${escapeHtml(suggestion.proposed_file_name)}" spellcheck="false"><p>${suggestion.changes_name ? `建议从“${escapeHtml(basename(suggestion.source))}”重命名` : "文件名清晰，无需额外判断"}</p></div>
    <div class="card"><label>识别到的内容</label><p class="summary">${escapeHtml(suggestion.summary || "没有可显示的摘要")}</p><div class="signals">${suggestion.signals.map(signal => `<span>${escapeHtml(signal)}</span>`).join("")}</div></div>
    <footer class="actions"><button class="ghost" id="dismiss">保留原位</button><button class="primary" id="confirm">确认</button></footer>
  </section>`;
}

function renderPathSuggestions(input?: HTMLInputElement): void {
  const container = document.querySelector<HTMLDivElement>("#path-suggestions");
  if (!container) return;
  container.innerHTML = folderPathSuggestions
    .filter(path => path !== input?.value)
    .map(path => `<button type="button" data-path-suggestion="${escapeHtml(path)}"><span>▱</span><strong>${escapeHtml(path)}</strong></button>`)
    .join("");
  container.querySelectorAll<HTMLButtonElement>("[data-path-suggestion]").forEach(button => {
    button.addEventListener("mousedown", event => event.preventDefault());
    button.addEventListener("click", () => {
      const destination = document.querySelector<HTMLInputElement>("#destination");
      if (destination) destination.value = button.dataset.pathSuggestion ?? destination.value;
      folderPathSuggestions = [];
      renderPathSuggestions(destination ?? undefined);
    });
  });
}

function bindPathAutocomplete(): void {
  const input = document.querySelector<HTMLInputElement>("#destination");
  if (!input) return;
  input.addEventListener("input", () => {
    if (pathSearchTimer !== undefined) window.clearTimeout(pathSearchTimer);
    const searchSequence = ++pathSearchSequence;
    const query = input.value.trim();
    if (query.length < 2) {
      folderPathSuggestions = [];
      renderPathSuggestions(input);
      return;
    }
    pathSearchTimer = window.setTimeout(async () => {
      const roots = [...new Set([...settings.roots, ...settings.watched])];
      const results = inTauri
        ? await invoke<string[]>("search_folders", { query, roots, limit: 8 }).catch(() => [])
        : [];
      if (searchSequence === pathSearchSequence
          && document.querySelector<HTMLInputElement>("#destination")?.value.trim() === query) {
        folderPathSuggestions = results;
        renderPathSuggestions(input);
      }
    }, 260);
  });
  input.addEventListener("focus", () => renderPathSuggestions(input));
  input.addEventListener("blur", () => window.setTimeout(() => {
    folderPathSuggestions = [];
    renderPathSuggestions(input);
  }, 120));
}

function appView(): string {
  const selected = suggestions.find(item => item.source === selectedSource) ?? suggestions[0];
  if (selected && selectedSource !== selected.source) selectedSource = selected.source;
  return `<div class="shell">
    <aside><div class="sidebar-brand"><div class="brand-mark small"><span></span></div><strong>SavePilot</strong></div>
      <button class="nav active"><span>⌁</span>审核队列 <b>${suggestions.length}</b></button>
      <div class="queue">${suggestions.map(item => `<button class="queue-item ${item.source === selectedSource ? "selected" : ""}" data-source="${escapeHtml(item.source)}"><strong>${escapeHtml(basename(item.source))}</strong><span>→ ${escapeHtml(basename(item.destination))}</span></button>`).join("")}</div>
      <div class="sidebar-bottom"><button class="nav" id="scan">↻　${scanning ? "扫描中…" : "扫描现有文件"}</button><button class="nav" id="settings">⚙　设置</button></div>
    </aside>
    <main class="workspace"><div class="topbar"><span class="status-dot"></span><span>后台监听中</span>${availableUpdate ? `<button class="update-badge" id="show-update" title="下载 ${escapeHtml(availableUpdate.version)}"><i></i>新版本</button>` : ""}<button class="icon-button" id="refresh-doctor" title="检查增强功能">✦</button></div>${detailView(selected)}</main>
    <dialog id="settings-dialog"><form method="dialog"><header><h2>设置</h2><button value="close" aria-label="关闭">×</button></header>
      <label>监听文件夹</label><div class="settings-list">${settings.watched.map(path => `<span>${escapeHtml(path)}<button type="button" data-remove-watch="${escapeHtml(path)}">移除</button></span>`).join("")}</div><button type="button" class="secondary" id="settings-add-watch">添加…</button>
      <label>归档根目录</label><div class="settings-list">${settings.roots.map(path => `<span>${escapeHtml(path)}<button type="button" data-remove-root="${escapeHtml(path)}">移除</button></span>`).join("")}</div><button type="button" class="secondary" id="settings-add-root">添加…</button>
      <label class="toggle"><input type="checkbox" id="autostart" ${settings.launchAtLogin ? "checked" : ""}> 登录系统时启动</label>
      <div class="enhancement"><strong>高级识别</strong><span>${doctor?.ollama.available ? `Ollama 已连接${doctor.ollama.models.length ? ` · ${doctor.ollama.models.length} 个模型` : ""}` : "Ollama 未连接（可选）"}</span><span>PDF ${doctor?.pdf ? "可用" : "基础模式"} · OCR ${doctor?.ocr ? "可用" : "未安装"}</span></div>
      <div class="dialog-actions"><div><button type="button" class="secondary" id="reindex">更新文件夹主题</button><button type="button" class="ghost compact" id="check-update">${checkingUpdate ? "检查中…" : "检查更新"}</button></div><button class="primary" value="close">完成</button></div>
    </form></dialog>
    <dialog id="update-dialog"><form method="dialog"><header><div><p class="eyebrow">UPDATE AVAILABLE</p><h2>发现新版本 ${availableUpdate ? escapeHtml(availableUpdate.version) : ""}</h2></div><button value="close" aria-label="关闭">×</button></header>
      <p class="update-title">${availableUpdate ? escapeHtml(availableUpdate.title) : ""}</p><div class="update-notes">${availableUpdate ? escapeHtml(availableUpdate.notes || "包含最新的功能改进和问题修复。") : ""}</div>
      <div class="dialog-actions"><button type="button" class="ghost" id="release-page">查看发布页</button><button type="button" class="primary" id="download-update">下载更新</button></div>
    </form></dialog>
  </div>`;
}

function bindCommon(): void {
  document.querySelectorAll<HTMLElement>("[data-remove-watch]").forEach(button => button.addEventListener("click", async () => {
    settings.watched = settings.watched.filter(path => path !== button.dataset.removeWatch);
    await saveSettings(); await startWatchers(); render();
    void warmFolderPathIndex();
  }));
  document.querySelectorAll<HTMLElement>("[data-remove-root]").forEach(button => button.addEventListener("click", async () => {
    settings.roots = settings.roots.filter(path => path !== button.dataset.removeRoot);
    await saveSettings(); render();
    void warmFolderPathIndex();
  }));
}

function render(): void {
  app.innerHTML = settings.completedWelcome ? appView() : welcomeView();
  bindCommon();
  document.querySelector("#add-watch")?.addEventListener("click", () => void chooseFolder("watch"));
  document.querySelector("#add-root")?.addEventListener("click", () => void chooseFolder("root"));
  document.querySelector("#start")?.addEventListener("click", () => void completeWelcome());
  document.querySelectorAll<HTMLElement>("[data-source]").forEach(button => button.addEventListener("click", () => { selectedSource = button.dataset.source ?? ""; render(); }));
  document.querySelector("#scan")?.addEventListener("click", () => void scanExisting());
  document.querySelector("#scan-empty")?.addEventListener("click", () => void scanExisting());
  document.querySelector("#confirm")?.addEventListener("click", () => void confirmSelected());
  bindPathAutocomplete();
  document.querySelector("#dismiss")?.addEventListener("click", dismissSelected);
  document.querySelector("#refresh-doctor")?.addEventListener("click", () => void refreshDoctor());
  document.querySelector("#show-update")?.addEventListener("click", () => (document.querySelector("#update-dialog") as HTMLDialogElement)?.showModal());
  document.querySelector("#check-update")?.addEventListener("click", () => void checkForUpdate(true));
  document.querySelector("#download-update")?.addEventListener("click", () => void downloadUpdate());
  document.querySelector("#release-page")?.addEventListener("click", () => {
    if (availableUpdate) void openUrl(availableUpdate.release_url);
  });
  document.querySelector("#settings")?.addEventListener("click", () => {
    (document.querySelector("#settings-dialog") as HTMLDialogElement)?.showModal();
    if (!doctor) void refreshDoctor();
  });
  document.querySelector("#settings-add-watch")?.addEventListener("click", () => void chooseFolder("watch"));
  document.querySelector("#settings-add-root")?.addEventListener("click", () => void chooseFolder("root"));
  document.querySelector("#reindex")?.addEventListener("click", () => void rebuildIndex());
  document.querySelector<HTMLInputElement>("#autostart")?.addEventListener("change", event => void toggleAutostart((event.target as HTMLInputElement).checked));
}

if (inTauri) settings.launchAtLogin = await isEnabled().catch(() => settings.launchAtLogin);
render();
if (settings.completedWelcome) {
  await startWatchers();
  void warmFolderPathIndex();
  void refreshDoctor();
}
if (inTauri) void checkForUpdate();
