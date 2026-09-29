# Focus

A macOS menubar app that keeps one queue of things waiting on you:

- **Jira** tickets in your active sprint that need a response from you
- **Slack** DMs, group DMs, thread replies and @mentions you haven't answered
- **Tasks** you add yourself, with or without a deadline

Whatever has waited longest is at the top. New Slack messages and new Jira replies jump
above everything else, but among those, the oldest still comes first. Colors show how long
something has waited in business hours: green, then amber, then red. A `focus` command line
tool drives the same queue, which is handy for scripts and AI agents.

## Install

Needs macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). You
don't need an Apple developer account.

### Before you build: set your company's values (required)

Focus has two company-wide settings that are built into the app. **Both are empty in this
repository, and you must fill them in before running `make install`.** Without them,
Settings will say Jira or Slack "isn't set up in this build".

Fill in the two `<string>` values in `Resources/Org.plist`, or (better, if you use git)
copy it to `Resources/Org.local.plist` and fill that in. The local file is ignored by git
and used instead when it exists, so your values never get committed:

```xml
<key>JiraSite</key>
<string>https://yourcompany.atlassian.net</string>     <!-- your Jira Cloud address -->
<key>SlackClientID</key>
<string>1234567890.1234567890</string>                  <!-- your company's Focus Slack app -->
```

- **`JiraSite`:** the address you use for Jira, with no trailing slash.
- **`SlackClientID`:** the Client ID of your company's own Focus Slack app. Someone creates
  that app once for everyone, using `slack-app-manifest.yaml`. See
  [Using Focus at another company](#using-focus-at-another-company-or-another-slack-workspace)
  for the steps. Leave it empty to use Focus without Slack.

Neither value is a secret. **Don't** put a Slack Client Secret, Signing Secret, or any
token in this file.

Then build:

```sh
cd focus
make install        # builds Focus.app into ~/Applications and `focus` into ~/.local/bin
```

`make install` warns you if either value is still empty, and opens Focus when it finishes.

`make install` opens Focus when it finishes. The crosshair icon in the menubar opens
Settings.

### Starting Focus

- **At login:** Focus turns on **Open at login** the first time it runs, so it starts with
  your Mac. Turn it off in Settings → General → Panel, or in System Settings → General →
  Login Items. macOS may show a "login item added" notice the first time.
- **By hand:** press Cmd+Space and type **Focus**. The app is installed in the
  Applications folder inside your home folder (`~/Applications`), not the system
  Applications folder, so it doesn't need an admin password. In Finder, use
  Go → Home → Applications.
- Focus lives in the menubar and has no Dock icon. To show or hide the panel, press
  **⌃⌥F** (Control-Option-F) from any app, middle-click the crosshair icon, or click it
  and choose Show / Hide Focus.

- **Jira:** turn on "Show my sprint tickets", enter your email and an Atlassian API token
  (Settings has a link to create one), then click Save & Test. The token is stored in your
  Keychain.
- **Slack:** turn on "Show my Slack messages" and click Connect Slack, then sign in and
  click Allow in the browser. Focus only reads; it never posts.

macOS may ask once whether Focus can use its Keychain item. Click Always Allow. Because the
app is built locally, it asks again after each rebuild.

## Using the queue

- **Click** an item to open it in Jira or Slack.
- **Hover** over an item for **Skip** (send it to the back of the line) and **Dismiss**
  (hide it until someone posts something new). Tasks get **Done** instead of Dismiss.
- **Add a task** with **+ Add** at the bottom, or click the panel and press Return.
  Writing "by 5pm" or "in 30 min" in the text sets a deadline.
- Slack items clear when you reply or react with an emoji. Jira tickets clear when you
  comment, and come back a business day later if nothing else has happened.
- **Settings → Try it** runs every behavior on demo items, so you can see what each one
  looks like without waiting for it to happen for real.

From the terminal: `focus list`, `focus add "call Sam by 3pm"`, `focus done <id>`,
`focus dismiss <id>`. Run `focus help` for the rest.

## How Focus's Slack access works

People sometimes read the permission list on the Focus Slack app ("View messages in a
user's direct messages", and so on) as access to everyone's messages. It isn't.

**The Slack app is only a registration.** It has a name, a list of permissions it may ask
for, and a sign-in address. On its own it can read nothing. It has no bot, no server, and
no shared key.

**Access only exists when a person clicks Connect Slack, then Allow.** At that moment Slack
creates a token for *that person*:

- It acts as them, so it can read only what they can already read in Slack: their own DMs
  and group DMs, private channels they're in, public channels, and their own search.
- It comes straight back to Focus on their own Mac and is stored in their macOS Keychain.
  It never passes through the app's creator or any server.
- Every person who connects gets a separate token. Nobody shares one.

"A user's direct messages" in the permission list means **the user who clicked Allow**. It
doesn't mean everyone in the workspace.

**What this means in practice:**

- You can't read anyone else's messages through Focus, and they can't read yours. Whoever
  created the Slack app has no special access either.
- Focus only reads. It has no permission to post, react, edit or delete.
- Your token is used only by Focus on your Mac, which talks only to `slack.com` (and your
  Jira site). You can check this in the source: `grep -rhoE 'https?://[a-zA-Z0-9.:-]+' Sources | sort -u`.
- **Disconnect** in Settings revokes your token at Slack and deletes it from your Mac. Slack
  admins can also see and revoke authorizations.

**The one thing to be careful about:** Focus runs as you, so build it only from this
repository, not from a copy someone sends you. A modified build could misuse your own
token, just as any app you sign into could.

## Using Focus at another company (or another Slack workspace)

Two company-wide values are built into the app when you run `make install`. They live in
[`Resources/Org.plist`](Resources/Org.plist):

| Key             | What it is                                    | Example                             |
|-----------------|-----------------------------------------------|-------------------------------------|
| `JiraSite`      | Your Jira Cloud site                          | `https://yourcompany.atlassian.net` |
| `SlackClientID` | The Client ID of your company's Focus Slack app | `1234567890.1234567890`           |

Neither value is secret. Users never see or edit them; one person sets them up for everyone.

### 1. Point Focus at your Jira

Open `Resources/Org.plist` and replace the `JiraSite` value:

```xml
<key>JiraSite</key>
<string>https://yourcompany.atlassian.net</string>
```

This is your Jira Cloud site with no trailing slash. Each person still enters their own
email and API token in Settings.

### 2. Create your own Focus Slack app (optional)

Slack apps belong to one workspace or organization, so another workspace needs its own
copy. Someone with permission to create apps does this once:

1. Go to https://api.slack.com/apps, click **Create New App**, choose **From a manifest**,
   and pick your workspace.
2. Paste this manifest. It's also in the repo as
   [`slack-app-manifest.yaml`](slack-app-manifest.yaml).

   ```yaml
   display_information:
     name: Focus
   oauth_config:
     redirect_urls:
       - http://localhost:53682/slack/callback
     scopes:
       user:
         - search:read
         - im:read
         - im:history
         - mpim:read
         - mpim:history
         - channels:history
         - groups:history
         - users:read
         - usergroups:read
     pkce_enabled: true
   settings:
     org_deploy_enabled: false
     socket_mode_enabled: false
     token_rotation_enabled: true
   ```

   - Every scope is a **user** scope and read-only. There's no bot, and Focus never posts.
   - `pkce_enabled` lets a desktop app sign in without a client secret. Turning it on can't
     be undone, and that's expected.
   - Keep the redirect URL exactly as written. Focus waits for it on this Mac only, during
     sign-in.
3. Open the app's **Basic Information** page and copy the **Client ID**. It looks like
   `1234567890.1234567890`. Put it in `Resources/Org.plist`:

   ```xml
   <key>SlackClientID</key>
   <string>1234567890.1234567890</string>
   ```

   **Don't** copy the Client Secret or the Signing Secret (the long hex values). Focus
   never needs them, and they shouldn't go anywhere. If you paste one somewhere by
   mistake, regenerate it on the same page.
4. The first person to click Connect Slack may see "Request to install". Your Slack admins
   approve the scopes once, and some organizations approve automatically. After that,
   anyone in the workspace can connect. Adding scopes later means another approval, so
   keep the manifest as it is.

To build without Slack, leave `SlackClientID` empty. The Slack section in Settings will
say it isn't set up.

### 3. Build

```sh
make install
```

You can also set the values on the command line instead of editing the file:

```sh
make install JIRA_SITE=https://yourcompany.atlassian.net SLACK_CLIENT_ID=1234567890.1234567890
```

To check what went into a build:

```sh
/usr/libexec/PlistBuddy -c Print ~/Applications/Focus.app/Contents/Resources/Org.plist
```

## Development

```sh
make build     # compile
make test      # unit tests (works with the Command Line Tools only)
make install   # build the app bundle and install it
```

`PLAN.md` records every design decision and why it was made. `DESIGN.md` has the original
design.
