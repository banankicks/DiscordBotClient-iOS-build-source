# iOS build

The native app is in `iOS/DiscordBotClient.xcodeproj` and targets iOS 17 or newer. It is a SwiftUI app and does not embed the desktop Discord web client. The desktop Electron app and its build remain separate.

## Build in Xcode

1. Open `iOS/DiscordBotClient.xcodeproj` on a Mac with Xcode installed.
2. Select the `DiscordBotClient` scheme and an iPhone device or generic iOS device destination.
3. Set the signing team in **Signing & Capabilities**. The bundle identifier is `com.aikochanai.discordbotclient`; change it if that identifier is unavailable in your Apple Developer account.
4. For a local device build, choose **Product → Archive**, then use **Distribute App** to export an IPA with an applicable Apple provisioning profile.

If your goal is only to try the app on your own iPhone, a Mac with Xcode is the simplest route: sign in to Xcode with your Apple Account, select a **Personal Team**, connect the phone, and press **Run**. Apple allows personal-device testing without paid membership, but Personal Team profiles expire after 7 days, so the app must be rebuilt and reinstalled periodically. This does not provide an App Store or durable IPA distribution path. [Apple account overview](https://developer.apple.com/help/account/basics/about-your-developer-account/)

## GitHub Actions IPA

To build without owning a Mac, extract `DiscordBotClient-iOS-build-source.zip`, create a GitHub repository, then push the extracted folder. For example, from PowerShell in the extracted folder:

```powershell
git init -b main
git add .
git commit -m "Add native iOS client"
git remote add origin https://github.com/YOUR-NAME/YOUR-REPOSITORY.git
git push -u origin main
```

Then run **Actions → Build iOS IPA → Run workflow**. GitHub-hosted runners provide macOS virtual machines for Actions jobs ([runner docs](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners)). With no signing secrets, it compiles the Release app and gives you an unsigned `.app` ZIP artifact for build verification; that app cannot be installed on an iPhone. With signing secrets configured, it also exports `DiscordBotClient.ipa` as a downloadable workflow artifact. A device-installable IPA needs an Apple Distribution certificate and a distribution provisioning profile that matches the bundle ID, selected export method, and registered device(s) for ad-hoc install. Add these repository secrets:

- `IOS_CERTIFICATE_BASE64`: base64-encoded `.p12` distribution certificate.
- `IOS_CERTIFICATE_PASSWORD`: password for the `.p12` file.
- `IOS_PROVISIONING_PROFILE_BASE64`: base64-encoded `.mobileprovision` profile.
- `IOS_TEAM_ID`: Apple Developer team ID.

Choose **ad-hoc** for registered-device sideloading or **app-store-connect** for App Store Connect distribution. The workflow intentionally fails before archiving if signing secrets are absent; it does not make or claim an unsigned IPA is installable. Never commit certificates, profiles, or bot tokens.

## Implemented native bot workflows

Bot profiles keep credentials in the iOS Keychain and profile labels in app preferences. The app validates bot authentication with Discord REST, discovers the Gateway URL, identifies with GUILDS and message intents, and adds the privileged Message Content intent only when the application flags indicate it is enabled. Guild/channel navigation, recent message history, live message create/update/delete events, send/edit/delete, image and file uploads, embed and attachment previews, and settings/profile management are implemented with native iOS controls. REST permissions and HTTP 429 responses are surfaced to the user.

Discord's desktop web-client compatibility routes, Vencord plugins, and web-only features are not part of this Swift target. The iOS client uses the official bot API surface and is constrained by bot permissions and approved Gateway intents. Gateway connectivity is foreground-oriented; iOS may suspend network activity when the app is backgrounded.
