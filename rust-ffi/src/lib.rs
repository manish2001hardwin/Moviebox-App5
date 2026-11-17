//! C-ABI bridge between the Flutter app and the MovieBox-TUI core.
//!
//! Three exported functions, everything else is JSON:
//!   mb_init(data_dir)            -> JSON string
//!   mb_call(method, args_json)   -> JSON string  {"ok":true,"data":..} | {"ok":false,"error":".."}
//!   mb_free(ptr)                 -> frees any string returned by the two above
//!
//! `mb_call` blocks until the async work finishes, so Dart must call it from a background isolate.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use moviebox_tui::providers::models::{PlaybackSource, ProviderKind, Release};
use moviebox_tui::providers::{ReleaseProvider, ResolutionIntent};
use moviebox_tui::service::MovieBoxService;
use serde_json::{Value, json};

struct State {
    rt: tokio::runtime::Runtime,
    svc: MovieBoxService,
    proxy: Mutex<Option<tokio::task::JoinHandle<()>>>,
    subtitle_dir: std::path::PathBuf,
}

static STATE: OnceLock<State> = OnceLock::new();

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .unwrap_or_default()
        .into_raw()
}

fn ok(data: Value) -> String {
    json!({ "ok": true, "data": data }).to_string()
}

fn err(msg: impl std::fmt::Display) -> String {
    json!({ "ok": false, "error": msg.to_string() }).to_string()
}

unsafe fn c_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// Must be called once, before any `mb_call`. `data_dir` is the app's private files dir.
#[unsafe(no_mangle)]
pub extern "C" fn mb_init(data_dir: *const c_char) -> *mut c_char {
    let dir = unsafe { c_str(data_dir) };
    let res = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        if STATE.get().is_some() {
            return Ok(());
        }
        let base = std::path::PathBuf::from(&dir);
        for sub in ["config", "data", "cache", "subtitles"] {
            let _ = std::fs::create_dir_all(base.join(sub));
        }
        // The core resolves its folders through the `dirs` crate, which reads these on Linux/Android.
        unsafe {
            std::env::set_var("HOME", &base);
            std::env::set_var("XDG_CONFIG_HOME", base.join("config"));
            std::env::set_var("XDG_DATA_HOME", base.join("data"));
            std::env::set_var("XDG_CACHE_HOME", base.join("cache"));
        }
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .thread_name("moviebox-rt")
            .build()
            .map_err(|e| e.to_string())?;
        let svc = rt.block_on(async { MovieBoxService::new() });
        let _ = STATE.set(State {
            rt,
            svc,
            proxy: Mutex::new(None),
            subtitle_dir: base.join("subtitles"),
        });
        Ok(())
    }));
    to_c(match res {
        Ok(Ok(())) => ok(json!(true)),
        Ok(Err(e)) => err(e),
        Err(_) => err("panic during init"),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn mb_call(method: *const c_char, args: *const c_char) -> *mut c_char {
    let method = unsafe { c_str(method) };
    let args = unsafe { c_str(args) };
    let out = catch_unwind(AssertUnwindSafe(|| {
        let Some(st) = STATE.get() else {
            return err("mb_init was not called");
        };
        let args: Value = match serde_json::from_str(&args) {
            Ok(v) => v,
            // Previously this silently fell back to `Value::Null`, which masked a malformed
            // call behind confusing downstream errors (e.g. "unknown provider ''"). Report it.
            Err(e) => return err(format!("invalid JSON arguments: {e}")),
        };
        match st.rt.block_on(dispatch(st, &method, args)) {
            Ok(v) => ok(v),
            Err(e) => err(e),
        }
    }))
    .unwrap_or_else(|_| err("internal panic"));
    to_c(out)
}

#[unsafe(no_mangle)]
pub extern "C" fn mb_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}

// ---------------------------------------------------------------------------------------------

fn s(args: &Value, key: &str) -> String {
    args.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn n(args: &Value, key: &str, default: usize) -> usize {
    args.get(key)
        .and_then(Value::as_u64)
        .map(|v| v as usize)
        .unwrap_or(default)
}

fn provider(args: &Value) -> Result<ProviderKind, String> {
    let name = s(args, "provider");
    ProviderKind::parse(&name).ok_or_else(|| format!("unknown provider '{name}'"))
}

fn json_of<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

async fn dispatch(st: &State, method: &str, args: Value) -> Result<Value, String> {
    let svc = &st.svc;
    match method {
        "providers" => {
            let list: Vec<Value> = ProviderKind::ENABLED
                .iter()
                .map(|p| json!({ "id": p.cache_key(), "label": p.label() }))
                .collect();
            Ok(json!(list))
        }

        "suggest" => json_of(&svc.suggest(&s(&args, "query")).await?),

        "search" => {
            let items = svc
                .search_typed(provider(&args)?, &s(&args, "query"), n(&args, "page", 1))
                .await
                .map_err(|e| e.to_string())?;
            json_of(&items)
        }

        "homepage" => {
            let tab = {
                let t = s(&args, "tab");
                if t.is_empty() { "2".to_string() } else { t }
            };
            let (items, metrics) = svc.homepage(&tab, n(&args, "page", 1)).await?;
            Ok(json!({ "items": json_of(&items)?, "metrics": json_of(&metrics)? }))
        }

        "details" => {
            let d = svc
                .details_typed(provider(&args)?, &s(&args, "id"))
                .await
                .map_err(|e| e.to_string())?;
            json_of(&d)
        }

        "streams" => {
            let kind = provider(&args)?;
            let id = s(&args, "id");
            let (season, episode) = (n(&args, "season", 0), n(&args, "episode", 0));
            let fut = async {
                match kind {
                    ProviderKind::MovieBox => {
                        ReleaseProvider::episode_streams(&svc.client, &id, season, episode).await
                    }
                    ProviderKind::FourKHdHub => match svc.fourk_client.as_ref() {
                        Some(c) => ReleaseProvider::episode_streams(c, &id, season, episode).await,
                        None => Err(moviebox_tui::providers::models::ProviderError::Unavailable(
                            "4KHDHub is unavailable".into(),
                        )),
                    },
                    ProviderKind::Dramachi => {
                        ReleaseProvider::episode_streams(&svc.dramachi_client, &id, season, episode)
                            .await
                    }
                    ProviderKind::BdixCircleFtp => {
                        ReleaseProvider::episode_streams(
                            &svc.circleftp_client,
                            &id,
                            season,
                            episode,
                        )
                        .await
                    }
                    ProviderKind::BdixDhakaFlix => {
                        ReleaseProvider::episode_streams(
                            &svc.dhakaflix_client,
                            &id,
                            season,
                            episode,
                        )
                        .await
                    }
                    ProviderKind::Addons => Err(moviebox_tui::providers::models::ProviderError::Unavailable(
                        "Addons are not supported in the mobile app yet".into(),
                    )),
                }
            };
            let releases = fut.await.map_err(|e| e.to_string())?;
            json_of(&releases)
        }

        // Turn a Release (+ chosen mirror) into a PlaybackSource, same rules as the TUI.
        "resolve" => {
            let release: Release =
                serde_json::from_value(args.get("release").cloned().unwrap_or(Value::Null))
                    .map_err(|e| format!("bad release: {e}"))?;
            let mirror_idx = n(&args, "mirror", 0);
            let mirror = release
                .mirrors
                .get(mirror_idx)
                .or_else(|| release.mirrors.first())
                .cloned()
                .ok_or("No playable mirrors were found for this release.")?;

            if release.provider == ProviderKind::FourKHdHub {
                let client = svc.fourk_client.clone().ok_or("4KHDHub is unavailable")?;
                let src = tokio::time::timeout(
                    Duration::from_secs(18),
                    client.resolve_release(&release, ResolutionIntent::Playback),
                )
                .await
                .map_err(|_| "4KHDHub: timed out".to_string())?
                .map_err(|e| e.user_message().to_string())?;
                return json_of(&src);
            }

            // UI can cap quality (Auto/1080/720/480) for multi-resolution (DASH) streams.
            let max_height = args
                .get("max_height")
                .and_then(Value::as_u64)
                .filter(|&h| h > 0)
                .or_else(|| Some(release.resolution_u64()).filter(|&h| h > 0));
            json_of(&PlaybackSource {
                provider: release.provider,
                url: mirror.resolver_url,
                headers: mirror.headers,
                subtitle: None,
                source_label: mirror.label,
                max_height,
            })
        }

        "captions" => {
            let siblings: Vec<String> = args
                .get("siblings")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            let caps = tokio::time::timeout(
                Duration::from_secs(15),
                svc.get_ext_captions(
                    &s(&args, "subject_id"),
                    &s(&args, "resource_id"),
                    &siblings,
                    n(&args, "season", 0),
                    n(&args, "episode", 0),
                ),
            )
            .await
            .map_err(|_| "subtitle lookup timed out".to_string())??;
            json_of(&caps)
        }

        // Decide how the player should open a PlaybackSource.
        //  - DASH (MovieBox): start the in-process proxy, hand the player a 127.0.0.1 URL.
        //  - everything else: hand the player the original URL + headers (libmpv accepts them).
        "prepare_play" => {
            let src: PlaybackSource =
                serde_json::from_value(args.get("source").cloned().unwrap_or(Value::Null))
                    .map_err(|e| format!("bad source: {e}"))?;
            let subtitle = args
                .get("subtitle")
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .map(str::to_string)
                .or(src.subtitle.clone());

            stop_proxy(st);

            if moviebox_tui::player::is_dash_url(&src.url) {
                let (tx, rx) = tokio::sync::oneshot::channel();
                let handle = tokio::spawn(moviebox_tui::proxy::run_proxy(
                    src.url.clone(),
                    src.headers.clone(),
                    subtitle.clone(),
                    src.max_height,
                    Some(tx),
                ));
                let port = tokio::time::timeout(Duration::from_secs(8), rx)
                    .await
                    .map_err(|_| "proxy start timed out".to_string())?
                    .map_err(|_| "proxy failed to bind".to_string())?;
                *st.proxy.lock().unwrap_or_else(|p| p.into_inner()) = Some(handle);

                let path = if let Some(rest) = src.url.strip_prefix("https://") {
                    format!("/https/{rest}")
                } else if let Some(rest) = src.url.strip_prefix("http://") {
                    format!("/http/{rest}")
                } else {
                    format!("/https/{}", src.url)
                };
                let sub = subtitle.as_deref().map(|remote| {
                    format!(
                        "http://127.0.0.1:{port}/sub/{}",
                        percent_encoding::utf8_percent_encode(
                            remote,
                            percent_encoding::NON_ALPHANUMERIC
                        )
                    )
                });
                return Ok(json!({
                    "url": format!("http://127.0.0.1:{port}{path}"),
                    "headers": [],
                    "subtitle": sub,
                    "proxied": true,
                }));
            }

            let mut local_sub: Option<String> = None;
            if let Some(url) = subtitle.as_deref() {
                match tokio::time::timeout(
                    Duration::from_secs(12),
                    svc.download_subtitle_file(url, &src.headers, None),
                )
                .await
                {
                    Ok(Ok(path)) => local_sub = Some(path.to_string_lossy().into_owned()),
                    other => log::warn!("subtitle download failed: {other:?}"),
                }
            }
            Ok(json!({
                "url": src.url,
                "headers": src.headers,
                "subtitle": local_sub,
                "proxied": false,
            }))
        }

        "stop_proxy" => {
            stop_proxy(st);
            Ok(json!(true))
        }

        // Download a subtitle file (with the stream's headers) and return its local path.
        "subtitle_fetch" => {
            let url = s(&args, "url");
            let name = s(&args, "name");
            let headers: Vec<(String, String)> = args
                .get("headers")
                .and_then(|h| serde_json::from_value(h.clone()).ok())
                .unwrap_or_default();
            let path = tokio::time::timeout(
                Duration::from_secs(20),
                svc.download_subtitle_file(
                    &url,
                    &headers,
                    if name.is_empty() { None } else { Some(name.as_str()) },
                ),
            )
            .await
            .map_err(|_| "subtitle download timed out".to_string())??;
            Ok(json!(path.to_string_lossy()))
        }

        "subtitle_dir" => Ok(json!(st.subtitle_dir.to_string_lossy())),

        other => Err(format!("unknown method '{other}'")),
    }
}

fn stop_proxy(st: &State) {
    if let Some(h) = st.proxy.lock().unwrap_or_else(|p| p.into_inner()).take() {
        h.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, args: Value) -> Value {
        let m = CString::new(method).unwrap();
        let a = CString::new(args.to_string()).unwrap();
        let p = mb_call(m.as_ptr(), a.as_ptr());
        let out = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        mb_free(p);
        serde_json::from_str(&out).unwrap()
    }

    #[test]
    fn bridge_end_to_end() {
        let dir = std::env::temp_dir().join("mb_ffi_test");
        let d = CString::new(dir.to_string_lossy().as_ref()).unwrap();
        let p = mb_init(d.as_ptr());
        let init: Value =
            serde_json::from_str(unsafe { CStr::from_ptr(p) }.to_str().unwrap()).unwrap();
        mb_free(p);
        assert_eq!(init["ok"], true, "{init}");

        // provider list
        let r = call("providers", Value::Null);
        assert_eq!(r["ok"], true);
        assert!(r["data"].as_array().unwrap().len() >= 3, "{r}");

        // errors are reported, not panicked
        assert_eq!(call("nope", Value::Null)["ok"], false);

        // malformed JSON args must return an explicit error, not silently become Null
        // (regression test for the previous unwrap_or(Value::Null) fallback).
        {
            let m = CString::new("search").unwrap();
            let bad = CString::new("{not valid json").unwrap();
            let p = mb_call(m.as_ptr(), bad.as_ptr());
            let out = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
            mb_free(p);
            let r: Value = serde_json::from_str(&out).unwrap();
            assert_eq!(r["ok"], false, "{r}");
            assert!(
                r["error"].as_str().unwrap_or("").contains("invalid JSON"),
                "{r}"
            );
        }
        assert_eq!(call("search", json!({"provider":"bogus"}))["ok"], false);
        assert_eq!(call("resolve", json!({"release": 5}))["ok"], false);

        // DASH url -> in-process proxy must start and accept TCP connections
        let r = call(
            "prepare_play",
            json!({"source": {
                "provider": "moviebox", "url": "https://example.com/video/manifest.mpd",
                "headers": [["Referer","https://example.com"]], "subtitle": null,
                "source_label": "t", "max_height": 720 }}),
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["data"]["proxied"], true);
        let url = r["data"]["url"].as_str().unwrap();
        assert!(url.starts_with("http://127.0.0.1:"), "{url}");
        let port: u16 = url["http://127.0.0.1:".len()..]
            .split('/')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        std::net::TcpStream::connect(("127.0.0.1", port)).expect("proxy not listening");
        assert_eq!(call("stop_proxy", Value::Null)["ok"], true);
    }
}
