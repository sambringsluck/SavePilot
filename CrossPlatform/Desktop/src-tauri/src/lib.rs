use serde_json::Value;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};
use tauri_plugin_shell::ShellExt;

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_notification::init())
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
