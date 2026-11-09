# iOS build

The native app is in `iOS/DiscordBotClient.xcodeproj` and targets iOS 17 or newer. It is a SwiftUI app and does not embed the desktop Discord web client. The desktop Electron app and its build remain separate.

## Build in Xcode

1. Open `iOS/DiscordBotClient.xcodeproj` on a Mac with Xcode installed.
2. Select the `DiscordBotClient` scheme and an iPhone device or generic iOS device destination.
3. Set the signing team in **Signing & Capabilities**. The bundle identifier is `com.aikochanai.discordbotclient`; change it if that identifier is unavailable in your Apple Developer account.
4. For a local device build, choose **Product → Archive**, then use **Distribute App** to export an IPA with an applicable Apple provisioning profile.

If your goal is only to try the app on your own iPhone, a Mac with Xcode is the simplest route: sign in to Xcode with your Apple Account, select a **Personal Team**, connect the phone, and press **Run**. Apple allows personal-device testing without paid membership, but Personal Team profiles expire after 7 days, so the app must be rebuilt and reinstalled periodically. This does not provide an App Store or durable IPA distribution path. [Apple account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/)

## GitHub Actions IPA

To build without owning a Mac, extract `DiscordBotClient-iOS-build-source.zip`, create a GitHub repository, then push the extracted folder. Run these commands from PowerShell in the extracted folder (omit `git init` if the repository is already initialized):

```powershell
git init -b main
git add -- iOS .github/workflows/ios-ipa.yml docs/ios-build.md
git config user.name "YOUR GITHUB NAME"
git config user.email "YOUR VERIFIED OR GITHUB NOREPLY EMAIL"
git commit -m "Add native iOS client"
git remote add origin https://github.com/YOUR-NAME/YOUR-REPOSITORY.git
git push -u origin main
```

If `origin` already exists, don't add it a second time; check it with `git remote -v` and keep using that remote. The explicit `git add` paths above avoid staging the desktop source if you run the commands in the larger desktop project folder.

Then run **Actions → Build unsigned iOS IPA → Run workflow**. GitHub-hosted runners provide macOS virtual machines for Actions jobs ([runner docs](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners)). No Apple signing secrets are needed: the workflow compiles with code signing disabled and packages the app as `DiscordBotClient.ipa`. Download the `DiscordBotClient-unsigned-ipa` artifact from the completed run and extract the IPA from GitHub's artifact ZIP.

The IPA is unsigned when built, but iOS still requires a valid signature to install and launch an app. Apple's device rejects a missing or invalid signature ([Apple code-signing docs](https://developer.apple.com/documentation/xcode/using-the-latest-code-signature-format)). Use a sideload tool such as [Sideloadly for Windows](https://sideloadly.io/): load the IPA, connect the iPhone, provide your Apple ID, and let Sideloadly sign and install it. Sideloadly says it supports free Apple IDs; those installs expire after 7 days and need refreshing/reinstalling. [Sideloadly](https://sideloadly.io/)

Never put your Apple ID password, bot token, or other credentials in the repository.

## Implemented native bot workflows

Bot profiles keep credentials in the iOS Keychain and profile labels in app preferences. The app validates bot authentication with Discord REST, discovers the Gateway URL, identifies with GUILDS and message intents, and adds the privileged Message Content intent only when the application flags indicate it is enabled. Guild/channel navigation, recent message history, live message create/update/delete events, send/edit/delete, image and file uploads, embed and attachment previews, and settings/profile management are implemented with native iOS controls. REST permissions and HTTP 429 responses are surfaced to the user.

Discord's desktop web-client compatibility routes, Vencord plugins, and web-only features are not part of this Swift target. The iOS client uses the official bot API surface and is constrained by bot permissions and approved Gateway intents. Gateway connectivity is foreground-oriented; iOS may suspend network activity when the app is backgrounded.
