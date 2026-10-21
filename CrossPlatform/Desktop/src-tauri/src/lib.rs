use semver::Version;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{HashSet, VecDeque},
    fs,
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};
use tauri_plugin_shell::ShellExt;

const RELEASES_API: &str = "https://api.github.com/repos/sambringsluck/SavePilot/releases?per_page=12";
const RELEASES_ATOM: &str = "https://github.com/sambringsluck/SavePilot/releases.atom";
// Installer ecosystems impose stricter package-version syntax than GitHub
// prerelease tags. Keep update identity independent from MSI/RPM metadata.
const CURRENT_RELEASE_VERSION: &str = "1.2.0-preview.10";

#[derive(Deserialize)]
struct ReleaseAsset {
    name: String,
    browser_download_url: String,
}

#[derive(Deserialize)]
struct GithubRelease {
    tag_name: String,
    name: Option<String>,
    body: Option<String>,
    html_url: String,
    draft: bool,
    assets: Vec<ReleaseAsset>,
}

#[derive(Serialize)]
struct UpdateInfo {
    current_version: String,
    version: String,
    title: String,
    notes: String,
    download_url: String,
    release_url: String,
}

async fn engine_json(app: &AppHandle, arguments: Vec<String>) -> Result<Value, String> {
    let output = app
        .shell()
        .sidecar("savepilot-engine")
        .map_err(|error| error.to_string())?
        .args(arguments)
        .output()
        .await
        .map_err(|error| error.to_string())?;

    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(if message.is_empty() { "SavePilot engine failed".into() } else { message });
    }
    serde_json::from_slice(&output.stdout).map_err(|error| format!("Invalid engine response: {error}"))
}

#[tauri::command]
async fn analyze_file(app: AppHandle, path: String, roots: Vec<String>) -> Result<Value, String> {
    let mut arguments = vec!["analyze".into(), "--file".into(), path];
    for root in roots {
        arguments.extend(["--root".into(), root]);
    }
    engine_json(&app, arguments).await
}

#[tauri::command]
async fn scan_existing(
    app: AppHandle,
    watched: Vec<String>,
    roots: Vec<String>,
    limit: u16,
) -> Result<Value, String> {
    let mut arguments = vec!["scan".into(), "--limit".into(), limit.to_string()];
    for path in watched {
        arguments.extend(["--watch".into(), path]);
    }
    for root in roots {
        arguments.extend(["--root".into(), root]);
    }
    engine_json(&app, arguments).await
}

#[tauri::command]
async fn confirm_suggestion(
    app: AppHandle,
    source: String,
    destination: String,
    name: String,
) -> Result<Value, String> {
    engine_json(
        &app,
        vec![
            "confirm".into(),
            "--source".into(), source,
            "--destination".into(), destination,
            "--name".into(), name,
        ],
    )
    .await
}

#[tauri::command]
async fn rebuild_index(app: AppHandle, roots: Vec<String>) -> Result<Value, String> {
    let mut arguments = vec!["index".into()];
    for root in roots {
        arguments.extend(["--root".into(), root]);
    }
    engine_json(&app, arguments).await
}

#[tauri::command]
async fn engine_doctor(app: AppHandle) -> Result<Value, String> {
    engine_json(&app, vec!["doctor".into()]).await
}

fn normalized_path_term(value: &str) -> String {
    value
        .to_lowercase()
        .replace('_', " ")
        .replace('-', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Clone)]
struct FolderPathEntry {
    path: String,
    full_key: String,
    leaf_key: String,
    components: Vec<String>,
    tokens: HashSet<String>,
    depth: usize,
}

impl FolderPathEntry {
    fn new(path: PathBuf) -> Self {
        let display_path = path.to_string_lossy().into_owned();
        let full_key = normalized_path_term(&display_path);
        Self {
            path: display_path,
            leaf_key: path
                .file_name()
                .map(|value| normalized_path_term(&value.to_string_lossy()))
                .unwrap_or_default(),
            components: path
                .components()
                .map(|value| normalized_path_term(&value.as_os_str().to_string_lossy()))
                .collect(),
            tokens: full_key.split_whitespace().map(str::to_owned).collect(),
            depth: path.components().count(),
            full_key,
        }
    }
}

#[derive(Default)]
struct FolderPathCache {
    roots: Vec<String>,
    entries: Vec<FolderPathEntry>,
}

static FOLDER_PATH_CACHE: OnceLock<Mutex<FolderPathCache>> = OnceLock::new();

fn path_match_score(query: &str, entry: &FolderPathEntry) -> Option<i32> {
    if entry.full_key == query || entry.leaf_key == query {
        Some(120)
    } else if entry.leaf_key.starts_with(query) {
        Some(108)
    } else if entry.leaf_key.contains(query) {
        Some(98)
    } else if let Some(index) = entry.components.iter().rposition(|value| value == query) {
        let descendants = entry.components.len().saturating_sub(index + 1) as i32;
        Some(94 - (descendants * 3).min(18))
    } else if entry.full_key.contains(query) {
        Some(82)
    } else {
        query
            .split_whitespace()
            .all(|value| entry.tokens.contains(value))
            .then_some(70)
    }
}

fn normalized_roots(mut roots: Vec<String>) -> Vec<String> {
    roots.sort();
    roots.dedup();
    roots
}

fn discover_folders(roots: &[String]) -> Vec<FolderPathEntry> {
    let excluded: HashSet<&str> = [
        ".git", ".build", "node_modules", "Library", "Applications", "Pods",
        "DerivedData", "Caches", "Cache",
    ]
    .into_iter()
    .collect();
    let mut visited = HashSet::new();
    let mut queue: VecDeque<(PathBuf, usize)> = roots
        .iter()
        .map(|value| (PathBuf::from(value), 0))
        .collect();
    while let Some((folder, depth)) = queue.pop_front() {
        if visited.len() >= 8_000 || !visited.insert(folder.clone()) {
            continue;
        }
        if depth >= 7 {
            continue;
        }
        let Ok(entries) = fs::read_dir(&folder) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || excluded.contains(name.as_str()) {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() && !kind.is_symlink() {
                queue.push_back((path, depth + 1));
            }
        }
    }
    let mut entries: Vec<_> = visited.into_iter().map(FolderPathEntry::new).collect();
    entries.sort_by(|left, right| left.path.cmp(&right.path));
    entries
}

fn ensure_folder_index(roots: Vec<String>, refresh: bool) -> usize {
    let roots = normalized_roots(roots);
    let cache = FOLDER_PATH_CACHE.get_or_init(|| Mutex::new(FolderPathCache::default()));
    {
        let current = cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !refresh && current.roots == roots && !current.entries.is_empty() {
            return current.entries.len();
        }
    }

    // Filesystem traversal happens only when the configured roots change (or on
    // explicit warm-up), never for each character typed in the destination field.
    let entries = discover_folders(&roots);
    let mut current = cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    current.roots = roots;
    current.entries = entries;
    current.entries.len()
}

fn rank_folder_entries(query: &str, entries: &[FolderPathEntry], limit: usize) -> Vec<String> {
    let query = normalized_path_term(query);
    if query.len() < 2 {
        return Vec::new();
    }
    let mut scored: Vec<_> = entries
        .iter()
        .filter_map(|entry| path_match_score(&query, entry).map(|score| (entry, score)))
        .collect();
    scored.sort_by(|left, right| {
        right.1.cmp(&left.1)
            .then_with(|| left.0.depth.cmp(&right.0.depth))
            .then_with(|| left.0.path.cmp(&right.0.path))
    });
    scored.into_iter().take(limit.clamp(1, 12))
        .map(|(entry, _)| entry.path.clone())
        .collect()
}

#[tauri::command]
async fn warm_folder_index(roots: Vec<String>) -> Result<usize, String> {
    tauri::async_runtime::spawn_blocking(move || ensure_folder_index(roots, true))
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn search_folders(query: String, roots: Vec<String>, limit: usize) -> Result<Vec<String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        ensure_folder_index(roots, false);
        let cache = FOLDER_PATH_CACHE.get_or_init(|| Mutex::new(FolderPathCache::default()));
        let current = cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        rank_folder_entries(&query, &current.entries, limit)
    })
        .await
        .map_err(|error| error.to_string())
}

fn asset_score(name: &str) -> Option<u8> {
    let name = name.to_ascii_lowercase();
    let platform_score = match std::env::consts::OS {
        "windows" if name.ends_with(".exe") => 30,
        "windows" if name.ends_with(".msi") => 20,
        "macos" if name.ends_with(".dmg") => 30,
        "linux" if name.ends_with(".appimage") => 30,
        "linux" if name.ends_with(".deb") => 20,
        "linux" if name.ends_with(".rpm") => 10,
        _ => return None,
    };
    let architecture_score = match std::env::consts::ARCH {
        "aarch64" if name.contains("aarch64") || name.contains("arm64") => 4,
        "x86_64" if name.contains("x64") || name.contains("x86_64") || name.contains("amd64") => 4,
        _ => 0,
    };
    Some(platform_score + architecture_score)
}

fn is_newer_release(current: &Version, candidate: &Version) -> bool {
    candidate > current
        || (current.major == 1
            && current.minor == 2
            && current.patch == 0
            && current.pre.is_empty()
            && candidate.major == current.major
            && candidate.minor == current.minor
            && candidate.patch == current.patch
            && !candidate.pre.is_empty())
}

fn update_from_atom(current: &Version, atom: &str) -> Option<UpdateInfo> {
    let marker = "/releases/tag/";
    let latest = atom.match_indices(marker)
        .filter_map(|(index, _)| {
            let rest = &atom[index + marker.len()..];
            let tag = rest.split(|character: char| {
                character == '"' || character == '<' || character == '&'
            }).next()?.trim();
            let version = Version::parse(tag.trim_start_matches('v')).ok()?;
            is_newer_release(current, &version).then_some((version, tag.to_owned()))
        })
        .max_by(|left, right| left.0.cmp(&right.0));
    let (version, tag) = latest?;
    let release_url = format!("https://github.com/sambringsluck/SavePilot/releases/tag/{tag}");
    let package_version = version.pre.as_str().strip_prefix("preview.")
        .map(|preview| format!("{}.{}.{}", version.major, version.minor, preview))
        .unwrap_or_else(|| version.to_string());
    let asset_name = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("windows", "x86_64") => Some(format!("SavePilot_{package_version}_x64-setup.exe")),
        ("macos", "aarch64") => Some(format!("SavePilot_{package_version}_aarch64.dmg")),
        ("linux", "x86_64") => Some(format!("SavePilot_{package_version}_amd64.AppImage")),
        _ => None,
    };
    let download_url = asset_name
        .map(|name| format!("https://github.com/sambringsluck/SavePilot/releases/download/{tag}/{name}"))
        .unwrap_or_else(|| release_url.clone());
    Some(UpdateInfo {
        current_version: current.to_string(),
        version: version.to_string(),
        title: format!("SavePilot {tag}"),
        notes: "包含最新的功能改进和问题修复。".into(),
        download_url,
        release_url,
    })
}

#[tauri::command]
async fn check_for_update() -> Result<Option<UpdateInfo>, String> {
    let current = Version::parse(CURRENT_RELEASE_VERSION).map_err(|error| error.to_string())?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .user_agent(format!("SavePilot/{}", current))
        .build()
        .map_err(|error| error.to_string())?;
    // Prefer the public Atom feed. Unlike unauthenticated REST requests it is
    // not subject to GitHub's low shared API rate limit.
    if let Ok(response) = client.get(RELEASES_ATOM).send().await {
        if response.status().is_success() {
            if let Ok(atom) = response.text().await {
                if atom.contains("<feed") {
                    return Ok(update_from_atom(&current, &atom));
                }
            }
        }
    }
    let releases = client
        .get(RELEASES_API)
        .send()
        .await
        .map_err(|error| format!("Unable to check for updates: {error}"))?
        .error_for_status()
        .map_err(|error| format!("Update service returned an error: {error}"))?
        .json::<Vec<GithubRelease>>()
        .await
        .map_err(|error| format!("Invalid update response: {error}"))?;

    let latest = releases
        .into_iter()
        .filter(|release| !release.draft)
        .filter_map(|release| {
            Version::parse(release.tag_name.trim_start_matches('v'))
                .ok()
                .map(|version| (version, release))
        })
        .filter(|(version, _)| is_newer_release(&current, version))
        .max_by(|(left, _), (right, _)| left.cmp(right));

    let Some((version, release)) = latest else {
        return Ok(None);
    };
    let download_url = release
        .assets
        .iter()
        .filter_map(|asset| asset_score(&asset.name).map(|score| (score, asset)))
        .max_by_key(|(score, _)| *score)
        .map(|(_, asset)| asset.browser_download_url.clone())
        .unwrap_or_else(|| release.html_url.clone());

    Ok(Some(UpdateInfo {
        current_version: current.to_string(),
        version: version.to_string(),
        title: release.name.unwrap_or_else(|| release.tag_name.clone()),
        notes: release.body.unwrap_or_default(),
        download_url,
        release_url: release.html_url,
    }))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .setup(|app| {
            #[cfg(desktop)]
            app.handle().plugin(tauri_plugin_autostart::init(
                tauri_plugin_autostart::MacosLauncher::LaunchAgent,
                None,
            ))?;

            let show = MenuItem::with_id(app, "show", "打开 SavePilot", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            let mut tray = TrayIconBuilder::new()
                .tooltip("SavePilot")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_main_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main_window(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            analyze_file,
            scan_existing,
            confirm_suggestion,
            rebuild_index,
            engine_doctor,
            warm_folder_index,
            search_folders,
            check_for_update,
        ])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running SavePilot");
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

#[cfg(test)]
mod tests {
    use super::{is_newer_release, path_match_score, update_from_atom, FolderPathEntry};
    use std::path::PathBuf;
    use semver::Version;

    #[test]
    fn detects_normal_version_increase() {
        assert!(is_newer_release(
            &Version::parse("1.2.0-preview.3").unwrap(),
            &Version::parse("1.2.0-preview.5").unwrap()
        ));
        assert!(!is_newer_release(
            &Version::parse("1.2.0-preview.5").unwrap(),
            &Version::parse("1.2.0-preview.5").unwrap()
        ));
    }

    #[test]
    fn upgrades_legacy_preview_that_used_stable_version_number() {
        assert!(is_newer_release(
            &Version::parse("1.2.0").unwrap(),
            &Version::parse("1.2.0-preview.5").unwrap()
        ));
    }

    #[test]
    fn path_search_includes_descendants_of_matching_parent() {
        let parent = FolderPathEntry::new(PathBuf::from("/Users/test/Desktop/adv_econ"));
        let child = FolderPathEntry::new(PathBuf::from(
            "/Users/test/Desktop/adv_econ/industrial organization",
        ));
        assert_eq!(path_match_score("adv econ", &parent), Some(120));
        assert!(path_match_score("adv econ", &child).unwrap() >= 90);
    }

    #[test]
    fn atom_update_check_does_not_depend_on_api_quota() {
        let atom = r#"<feed><entry><link href="https://github.com/sambringsluck/SavePilot/releases/tag/v1.2.0-preview.8"/></entry></feed>"#;
        let update = update_from_atom(&Version::parse("1.2.0-preview.7").unwrap(), atom).unwrap();
        assert_eq!(update.version, "1.2.0-preview.8");
    }
}
