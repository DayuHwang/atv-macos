// SPDX-License-Identifier: GPL-3.0-or-later
// atv-macos: a `tvsign` command added to Sideloader's CLI (Dadoum/Sideloader).
//
// Sideloader's own `install` registers the device as an iPhone and installs
// over USB (usbmuxd), which reaches neither an Apple TV's device class nor an
// Apple TV with no USB port. `tvsign` does the account side for tvOS in one
// login, then stops: the Windows side installs the signed app itself over the
// Apple TV's network developer connection.
//
//   1. register the Apple TV (by UDID) as a tvOS development device
//   2. reuse or create the development certificate (Sideloader's own identity)
//   3. create the App ID <bundle id>.<team id> if missing
//   4. download the tvOS development profile for it
//   5. sign the .app folder in place with it
module tvsign;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv;
import std.exception;
import std.uni;

import slf4d;
import argparse;

import server.developersession;
import sideload.application;
import sideload.certificateidentity;
import sideload.sign: sideloadSign = sign;

import cli_frontend;

@(Command("tvsign").Description("Register an Apple TV and sign an app folder with a tvOS development profile (no installation)."))
struct TvSignCommand
{
    mixin LoginCommand;

    @(NamedArgument("udid").Description("UDID of the Apple TV.").Required())
    string udid;

    @(NamedArgument("name").Description("Name to register the Apple TV under."))
    string deviceName = "Apple TV";

    @(NamedArgument("team").Description("Team ID (default: the first team)."))
    string teamId = null;

    @(PositionalArgument(0, "app path").Description("The .app folder to sign in place."))
    string appFolder;

    int opCall()
    {
        auto log = getLogger();
        Application app = openAppFolder(appFolder);

        string configurationPath = systemConfigurationPath();
        scope provisioningData = initializeADI(configurationPath);
        scope adi = provisioningData.adi;
        scope akDevice = provisioningData.device;

        auto appleAccount = login(akDevice, adi);
        if (!appleAccount) {
            return 1;
        }

        auto teams = appleAccount.listTeams().unwrap();
        if (teamId != null) {
            teams = teams.filter!((t) => t.teamId == teamId).array();
        }
        enforce(teams.length > 0, "No matching team found.");
        auto team = teams[0];
        log.infoF!"Team: %s (%s)"(team.name, team.teamId);

        // 1. the Apple TV as a tvOS development device
        auto devices = appleAccount.listDevices!tvOS(team).unwrap();
        if (devices.any!((d) => d.deviceNumber.toLower() == udid.toLower())) {
            log.info("The Apple TV is already registered.");
        } else {
            log.infoF!"Registering %s (%s) as a tvOS development device..."(deviceName, udid);
            appleAccount.addDevice!tvOS(team, deviceName, udid).unwrap();
        }

        // 2. development certificate and key, kept in Sideloader's configuration folder
        auto certIdentity = new CertificateIdentity(configurationPath, appleAccount);

        // 3. a unique App ID: the bundle identifier with the team ID appended
        string bundleId = app.bundleIdentifier();
        string appIdStr = bundleId.endsWith("." ~ team.teamId) ? bundleId : bundleId ~ "." ~ team.teamId;
        app.bundleIdentifier = appIdStr;

        auto appIdList = appleAccount.listAppIds!tvOS(team).unwrap();
        if (!appIdList.appIds.canFind!((a) => a.identifier == appIdStr)) {
            enforce(appIdList.availableQuantity > 0,
                "This Apple ID has no App IDs left for now (free accounts get 10 a week).");
            string appIdName = app.bundleName().filter!((dchar c) => c.isAlphaNum).array().to!string();
            if (appIdName.length == 0) {
                appIdName = "atvmacos";
            }
            log.infoF!"Creating App ID %s..."(appIdStr);
            appleAccount.addAppId!tvOS(team, appIdStr, appIdName).unwrap();
            appIdList = appleAccount.listAppIds!tvOS(team).unwrap();
        }
        auto appId = appIdList.appIds.find!((a) => a.identifier == appIdStr)[0];

        // 4. the tvOS development profile (it lists the registered Apple TV)
        log.info("Downloading the tvOS development profile...");
        auto profile = appleAccount.downloadTeamProvisioningProfile!tvOS(team, appId).unwrap();

        // 5. sign in place
        log.infoF!"Signing %s as %s..."(app.bundleName(), appIdStr);
        ProvisioningProfile[string] profiles;
        profiles[appIdStr] = profile;
        sideloadSign(app, certIdentity, profiles, delegate(double progress) {}, true);
        log.info("Signed. Install it with atv_install.py.");
        return 0;
    }
}
