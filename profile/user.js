// Claude Browser: the profile's preferences. install.sh copies this file
// into the profile; Firefox reads it at every start.

// Developer Edition: runs the Claude Bridge extension, which is not signed
// by Mozilla, and enables it without asking (it sits in the profile's
// extensions/ as a proxy file)
user_pref("xpinstall.signatures.required", false);
user_pref("extensions.autoDisableScopes", 0);

// no first-run pages, no nagging
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
user_pref("browser.profiles.enabled", false);

// nothing sent home
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.usage.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);

// no remote debugging: it would set navigator.webdriver = true on every
// page and get the browser treated as a bot. The bridge does not need it.
user_pref("devtools.debugger.remote-enabled", false);
user_pref("devtools.chrome.enabled", false);

// the last session comes back, also after a crash
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
