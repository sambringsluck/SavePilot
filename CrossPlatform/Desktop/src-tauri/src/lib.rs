use semver::Version;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};
use tauri_plugin_shell::ShellExt;

const RELEASES_API: &str = "https://api.github.com/repos/sambringsluck/SavePilot/releases?per_page=12";
// Installer ecosystems impose stricter package-version syntax than GitHub
// prerelease tags. Keep update identity independent from MSI/RPM metadata.
const CURRENT_RELEASE_VERSION: &str = "1.2.0-preview.6";

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

#[tauri::command]
async fn check_for_update() -> Result<Option<UpdateInfo>, String> {
    let current = Version::parse(CURRENT_RELEASE_VERSION).map_err(|error| error.to_string())?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .user_agent(format!("SavePilot/{}", current))
        .build()
        .map_err(|error| error.to_string())?;
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
    use super::is_newer_release;
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
}
