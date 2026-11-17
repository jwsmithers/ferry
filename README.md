# Ferry

A stupidly simple Mac app for browsing a server over SSH and moving files up and down.

Ferry uses your existing `~/.ssh/config`, keys and agent, so there's nothing to set up: if `ssh myserver` works in Terminal, Ferry works.

## Features

- **Browse.** Pick a host from your SSH config (or type `user@host`), then double-click folders or paste a path. Back, forward, up, home, and a hidden-files toggle.
- **Download.** Select files or folders and press ⌘D to save them to Downloads, or right-click → *Download To…*. Existing local files are never overwritten (you get `name 2.ext`).
- **Upload.** Drag files or folders from Finder onto the window, or press ⌘U. Ferry asks before replacing anything already on the server.
- **View.** Double-click a file to open it in its default Mac app.
- **Transfers panel.** Progress, speed and cancel for every transfer; up to 3 run at once.
- **The basics.** New folder, rename, delete (with confirmation), copy path.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10 or later (Xcode 15.3+ or its Command Line Tools) to build
- **A Linux server.** Ferry runs standard GNU tools on the remote side (`find`, `tar`, `cat`, `du`), so a Linux server works. macOS and BSD servers don't, because their `find` lacks `-printf`.
- **Key-based SSH login.** Ferry never shows a password prompt, so authentication must work without typing anything: an SSH key, `ssh-agent`, or a `ProxyCommand` such as a cloud tunnel.

## Install

There are no prebuilt binaries. Build it from source:

```bash
git clone <this repo>
cd ferry
./build.sh            # builds build/Ferry.app
./build.sh install    # also copies it to /Applications (or ~/Applications)
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Double-click | Open folder, or open file in its default app |
| ⌘[ / ⌘] | Back / forward |
| ⌘↑ | Enclosing folder |
| ⇧⌘H | Home folder |
| ⌘R | Refresh |
| ⇧⌘. | Show / hide hidden files |
| ⇧⌘N | New folder |
| ⌘U | Upload |
| ⌘D | Download selection to Downloads |
| ⌫ | Delete selection (asks first) |

## How it works

Ferry is a thin UI over the `ssh` binary on your `PATH`. It doesn't implement SSH itself.

- **One shared connection per host.** Ferry uses SSH connection multiplexing (`ControlMaster`). The first connection pays the full cost, which can be a few seconds through a cloud tunnel; after that each folder listing takes a fraction of a second. The connection closes 10 minutes after last use, or when Ferry quits. Its socket is at `/tmp/ferry-<hash>`.
- **Listings** run `find -printf` in the folder and parse the result.
- **Transfers** stream through Ferry so it can show progress: `cat` for single files, `tar` for folders. Nothing is written to temporary files on the server. Folder uploads leave out macOS metadata (no `._` files).
- **Your shell environment is loaded at launch.** Apps opened from Finder get a minimal `PATH`, so Ferry reads your login shell's environment. This lets tools your SSH config relies on, such as `gcloud` in a `ProxyCommand` or a Homebrew `ssh`, be found.
- **New hosts are trusted on first connect** (`StrictHostKeyChecking=accept-new`). A *changed* host key still fails, as it would in Terminal.
- **Files opened by double-click** go to your user temp folder. Ferry clears it on every launch, and macOS clears it on restart.

## Limitations

- You can't drag files out of Ferry into Finder. Use Download instead.
- Opened files are local copies, so edits aren't synced back to the server. Upload the file again.
- Cancelled uploads may leave a partial file on the server.
- Password and two-factor prompts aren't supported (see Requirements).

## Project layout

```
Sources/Ferry/
  FerryApp.swift      app entry point
  ConnectView.swift   host picker
  BrowserView.swift   file table, toolbar, dialogs
  BrowserModel.swift  navigation and file operations
  TransfersView.swift transfer list
  Transfers.swift     upload/download engine
  SSH.swift           ssh invocation, listing, ~/.ssh/config parsing
  Shell.swift         login-shell environment, process helpers
  Models.swift        file model, local path helpers
scripts/make_icon.swift  generates the app icon
build.sh                 builds and bundles Ferry.app
```

## License

[MIT](LICENSE)
