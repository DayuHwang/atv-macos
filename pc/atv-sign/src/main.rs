// SPDX-License-Identifier: GPL-2.0-or-later
//! atv-sign: signs the atv-macos app for one Apple TV with a free Apple ID.
//!
//! One login, then, all with the tvOS device type:
//!   1. register the Apple TV (UDID) as a development device
//!   2. reuse or create the development certificate (key kept in Windows Credential Manager)
//!   3. create the App ID <bundle id>.<team id> if needed, ask for the increased memory limit
//!   4. download the tvOS development profile
//!   5. sign the .app folder in place
//!
//! Built on isideload (MIT), whose login fetches anisette client info from a server:
//! Apple has refused locally generated client info since October 2026 (error -80045).
//!
//! Usage: atv-sign --udid <UDID> [--name <name>] [--team <id>] [--apple-id <email>]
//!                 [--no-memory-limit] <path to .app>

use std::future::Ready;
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use plist::{Dictionary, Value};

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::{AppIdsApi, Profile},
        certificates::DevelopmentCertificate,
        developer_session::DeveloperSession,
        device_type::{DeveloperDeviceType, dev_url},
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    sideload::{
        application::Application, builder::MaxCertsBehavior, cert_identity::CertificateIdentity, sign,
    },
    util::keyring_storage::KeyringStorage,
};

struct Args {
    udid: String,
    name: String,
    team: Option<String>,
    apple_id: Option<String>,
    memory_limit: bool,
    app: PathBuf,
}

fn usage(code: i32) -> ! {
    eprintln!(
        "usage: atv-sign --udid <UDID> [--name <name>] [--team <team id>] [--apple-id <email>] \
         [--no-memory-limit] <path to .app>"
    );
    std::process::exit(code)
}

fn parse_args() -> Args {
    let mut it = std::env::args().skip(1);
    let (mut udid, mut name, mut team, mut apple_id, mut memory_limit, mut app) =
        (None, "Apple TV".to_string(), None, None, true, None);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--udid" => udid = it.next(),
            "--name" => name = it.next().unwrap_or_else(|| usage(2)),
            "--team" => team = it.next(),
            "--apple-id" => apple_id = it.next(),
            "--no-memory-limit" => memory_limit = false,
            "-h" | "--help" => usage(0),
            s if s.starts_with("--") => usage(2),
            _ => app = Some(PathBuf::from(a)),
        }
    }
    Args {
        udid: udid.unwrap_or_else(|| usage(2)),
        name,
        team,
        apple_id,
        memory_limit,
        app: app.unwrap_or_else(|| usage(2)),
    }
}

fn read_line(prompt: &str) -> String {
    print!("{prompt}");
    let _ = io::stdout().flush();
    let mut s = String::new();
    let _ = io::stdin().read_line(&mut s);
    s.trim().to_string()
}

#[tokio::main]
async fn main() -> ExitCode {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("rustls crypto provider");
    isideload::init().expect("error reporting");
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_target(false)
        .init();

    let args = parse_args();
    match run(args).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("\n签名失败 / signing failed:\n{e}");
            ExitCode::FAILURE
        }
    }
}

type Error = Box<dyn std::fmt::Display>;

/// A developer-services request body: the team plus extra string fields.
fn body(team: &DeveloperTeam, extra: &[(&str, &str)]) -> Dictionary {
    let mut d = Dictionary::new();
    d.insert("teamId".into(), Value::String(team.team_id.clone()));
    for (k, v) in extra {
        d.insert((*k).into(), Value::String((*v).to_string()));
    }
    d
}

fn str_field(d: &Dictionary, key: &str) -> String {
    d.get(key).and_then(Value::as_string).unwrap_or_default().to_string()
}

fn first_line(s: &str) -> String {
    s.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim().trim_start_matches('●').trim().to_string()
}

/// The Platform list of a provisioning profile and whether it lists the UDID. The
/// profile is a CMS-signed plist; the XML sits in it as plain bytes.
fn inspect(profile: &[u8], udid: &str) -> (Vec<String>, bool) {
    let start = profile.windows(5).position(|w| w == b"<?xml");
    let end = profile.windows(8).rposition(|w| w == b"</plist>");
    let (Some(s), Some(e)) = (start, end) else { return (vec![], false) };
    let Ok(dict) = plist::from_bytes::<Dictionary>(&profile[s..e + 8]) else { return (vec![], false) };
    let strings = |key: &str| -> Vec<String> {
        dict.get(key)
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_string).map(str::to_string).collect())
            .unwrap_or_default()
    };
    let lists = strings("ProvisionedDevices").iter().any(|d| d.eq_ignore_ascii_case(udid));
    (strings("Platform"), lists)
}

fn fail<E: std::fmt::Display + 'static>(what: &'static str) -> impl FnOnce(E) -> Error {
    move |e| Box::new(format!("{what}: {e}"))
}

async fn run(args: Args) -> Result<(), Error> {
    if !args.app.is_dir() {
        return Err(Box::new(format!("not an .app folder: {}", args.app.display())));
    }

    let email = match &args.apple_id {
        Some(e) => e.clone(),
        None => read_line("Apple ID: "),
    };
    // Typed without echo, unlike older sideloading tools.
    let password = rpassword::prompt_password("密码 / Password (不会显示 / hidden): ")
        .map_err(fail("cannot read the password"))?;

    let two_factor = async |params: TwoFactorCallbackParams| {
        if params.unknown {
            println!("上一种验证方式没成功。The last 2FA method failed; pick another.");
        }
        let target = if params.sms {
            params
                .numbers
                .iter()
                .find(|n| Some(n.id) == params.selected_number_id)
                .map(|n| n.number_with_dial_code.clone())
                .unwrap_or_else(|| "your phone".into())
        } else {
            "你的苹果设备 / your Apple devices".into()
        };
        println!("双重认证验证码已发送到 {target}。");
        println!("  输入 6 位验证码；输入 d 改发到苹果设备；输入 r 重新发送。");
        for n in params.numbers.iter().filter(|n| Some(n.id) != params.selected_number_id) {
            println!("  输入 p{} 改发短信到 {}", n.id, n.number_with_dial_code);
        }
        let code = read_line("> ");
        Ok(if let Some(id) = code.strip_prefix('p').and_then(|s| s.parse::<u32>().ok()) {
            TwoFactorCallbackResponse::SendSms(id)
        } else if code == "d" {
            TwoFactorCallbackResponse::SendToDevices
        } else if code == "r" && !params.unknown {
            TwoFactorCallbackResponse::ResendCode
        } else {
            TwoFactorCallbackResponse::SubmitCode(code)
        })
    };

    println!("登录 Apple ID…");
    let anisette = RemoteV3AnisetteProvider::default()
        .map_err(fail("anisette provider"))?
        .set_serial_number("2".to_string());
    let mut account: AppleAccount = AppleAccount::builder(&email)
        .anisette_provider(anisette)
        .login(&password, two_factor)
        .await
        .map_err(fail("Apple ID login"))?;
    drop(password);

    let mut dev = DeveloperSession::from_account(&mut account)
        .await
        .map_err(fail("developer session"))?;

    let teams: Vec<DeveloperTeam> = dev.list_teams().await.map_err(fail("list teams"))?;
    let team = match &args.team {
        Some(id) => teams.into_iter().find(|t| &t.team_id == id),
        None => teams.into_iter().next(),
    }
    .ok_or_else(|| -> Error { Box::new("no matching development team") })?;
    println!("开发团队 / team: {} ({})", team.name.as_deref().unwrap_or("Personal Team"), team.team_id);

    // 1. the Apple TV as a development device. There is no tvos/ device list (it 404s):
    //    Apple TVs live in the same list as iPhones, told apart by their deviceClass.
    let ios = || DeveloperDeviceType::Ios;
    dev.ensure_device_registered(&team, &args.name, &args.udid, ios())
        .await
        .map_err(fail("register the Apple TV"))?;
    let devices: Vec<Dictionary> = dev
        .send_dev_request(&dev_url("listDevices", ios()), body(&team, &[]), "devices")
        .await
        .map_err(fail("list devices"))?;
    let class = devices
        .iter()
        .find(|d| str_field(d, "deviceNumber").eq_ignore_ascii_case(&args.udid))
        .map(|d| str_field(d, "deviceClass"))
        .unwrap_or_default();
    println!("Apple TV 已登记为开发设备 / registered: {} (deviceClass: {class})", args.udid);

    // 2. the development certificate; when the account is at its limit, ask which to revoke
    let storage = KeyringStorage::new("atv-macos".to_string());
    let revoke_prompt = async |certs: Vec<DevelopmentCertificate>| {
        println!("这个 Apple ID 的开发证书已满。输入要吊销的编号（逗号分隔），直接回车则放弃：");
        for (i, c) in certs.iter().enumerate() {
            println!(
                "  ({}) {}  {}",
                i + 1,
                c.name.as_deref().unwrap_or("?"),
                c.machine_name.as_deref().unwrap_or("")
            );
        }
        let picked: Vec<String> = read_line("> ")
            .split(',')
            .filter_map(|s| s.trim().parse::<usize>().ok())
            .filter(|&n| n >= 1 && n <= certs.len())
            .map(|n| certs[n - 1].serial_number.clone().unwrap_or_default())
            .collect();
        Ok(if picked.is_empty() { None } else { Some(picked) })
    };
    let identity = CertificateIdentity::retrieve(
        "atv-macos",
        &email,
        &mut dev,
        &team,
        &storage,
        &MaxCertsBehavior::Prompt(revoke_prompt),
    )
    .await
    .map_err(fail("development certificate"))?;
    println!("开发证书就绪 / certificate ready");

    // 3. the App ID: the bundle identifier with the team ID appended, unique on Apple's side
    let mut app = Application::new(args.app.clone()).map_err(fail("open the app"))?;
    let bundle_id = app.main_bundle_id().map_err(fail("bundle identifier"))?;
    let app_id_str = if bundle_id.ends_with(&format!(".{}", team.team_id)) {
        bundle_id.clone()
    } else {
        format!("{bundle_id}.{}", team.team_id)
    };
    app.update_bundle_id(&bundle_id, &app_id_str).map_err(fail("rename the bundle"))?;

    // App IDs are shared by all platforms; the ios/ endpoints are the ones that exist.
    let mut ids = dev.list_app_ids(&team, ios()).await.map_err(fail("list App IDs"))?;
    if !ids.app_ids.iter().any(|a| a.identifier == app_id_str) {
        if ids.available_quantity.is_some_and(|n| n <= 0) {
            return Err(Box::new("这个 Apple ID 本周的 App ID 名额用完了（免费账号每 7 天 10 个）。"));
        }
        println!("创建 App ID / creating App ID {app_id_str}");
        dev.add_app_id(&team, "atvmacos", &app_id_str, ios())
            .await
            .map_err(fail("create the App ID"))?;
        ids = dev.list_app_ids(&team, ios()).await.map_err(fail("list App IDs"))?;
    }
    let app_id = ids
        .app_ids
        .into_iter()
        .find(|a| a.identifier == app_id_str)
        .ok_or_else(|| -> Error { Box::new("the new App ID is not listed") })?;

    if args.memory_limit {
        match dev.add_increased_memory_limit(&team, &app_id).await {
            Ok(()) => println!("已申请提高内存上限 / increased memory limit enabled"),
            Err(e) => println!("提高内存上限没申请成功（不影响签名）/ memory limit not enabled: {e}"),
        }
    }

    // 4. the development profile for tvOS. The endpoint stays ios/ (there is no tvos/ one:
    //    it 404s); the platform goes in the body. Without it Apple builds an iOS profile and,
    //    with only an Apple TV on the team, answers 8220 "no devices". Both forms below were
    //    tested against Apple by other projects (Impactor PR #226, Apparition 51f689a).
    let candidates: [(&str, &[(&str, &str)]); 3] = [
        ("DTDK_Platform=tvos + subPlatform=tvOS", &[("DTDK_Platform", "tvos"), ("subPlatform", "tvOS")]),
        ("subPlatform=tvOS", &[("subPlatform", "tvOS")]),
        ("DTDK_Platform=tvos", &[("DTDK_Platform", "tvos")]),
    ];
    let mut chosen: Option<Profile> = None;
    let mut fallback: Option<Profile> = None;
    println!("获取描述文件 / profiles:");
    for (label, params) in candidates {
        let mut extra = vec![("appIdId", app_id.app_id_id.as_str())];
        extra.extend_from_slice(params);
        let got: Result<Profile, _> = dev
            .send_dev_request(&dev_url("downloadTeamProvisioningProfile", ios()), body(&team, &extra), "provisioningProfile")
            .await;
        let profile = match got {
            Ok(p) => p,
            Err(e) => {
                println!("  {label}: 失败 / failed: {}", first_line(&e.to_string()));
                continue;
            }
        };
        let (platforms, lists_tv) = inspect(profile.encoded_profile.as_ref(), &args.udid);
        println!("  {label}: \"{}\" platform={platforms:?} lists this Apple TV={lists_tv}", profile.name);
        let is_tvos = platforms.iter().any(|p| p.eq_ignore_ascii_case("tvos"));
        if is_tvos && lists_tv {
            chosen = Some(profile);
            break;
        }
        if lists_tv && fallback.is_none() {
            fallback = Some(profile);
        }
    }
    let profile = match (chosen, fallback) {
        (Some(p), _) => p,
        (None, Some(p)) => {
            println!("没拿到 tvOS 平台的描述文件，先用列有这台 Apple TV 的那份签名（安装可能被拒）。");
            p
        }
        (None, None) => {
            return Err(Box::new("没有任何一份描述文件列出这台 Apple TV。把上面的输出发给 Claude。"));
        }
    };
    println!("使用描述文件 / using profile: {}", profile.name);

    // 5. sign in place
    app.bundle.write_info().map_err(fail("write Info.plist"))?;
    sign::sign(
        &mut app,
        &identity,
        &profile,
        &mut Vec::new(),
        &None,
        &team,
        None::<fn(f32) -> Ready<()>>,
    )
    .await
    .map_err(fail("sign"))?;
    println!("签名完成 / signed: {} ({app_id_str})", args.app.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::inspect;

    #[test]
    fn reads_platform_and_devices_from_a_signed_profile() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Name</key><string>tvOS Team Provisioning Profile: x</string>
<key>Platform</key><array><string>tvOS</string></array>
<key>ProvisionedDevices</key><array><string>00008110-000578493E86801E</string></array>
</dict></plist>"#;
        // CMS wrapper bytes around the XML, as in a real .mobileprovision
        let mut der = vec![0x30, 0x82, 0x1f, 0x00, 0x06, 0x09, 0x2a, 0x86];
        der.extend_from_slice(xml.as_bytes());
        der.extend_from_slice(&[0xa0, 0x82, 0x0d, 0x30, 0x82, 0x04, 0x3c, 0x30]);
        let (platforms, lists) = inspect(&der, "00008110-000578493e86801e");
        assert_eq!(platforms, vec!["tvOS".to_string()]);
        assert!(lists);
        let (_, other) = inspect(&der, "00008110-0000000000000000");
        assert!(!other);
        assert_eq!(inspect(b"no plist here", "x"), (vec![], false));
    }
}
