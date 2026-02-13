# Messenger Desktop

A lightweight native macOS app that wraps [messenger.com](https://www.messenger.com) using Swift and WKWebView. No Electron, no Chromium — just WebKit and AppKit.

## Features

- **Persistent sessions** — cookies are saved to disk so you stay logged in across launches
- **Dock badge** — shows unread message count
- **Native notifications** — web notifications are bridged to macOS notification center
- **Video/audio calls** — camera and microphone permissions are supported
- **Keyboard shortcuts** — copy/paste, zoom (Cmd+/Cmd-), reload (Cmd+R), quit (Cmd+Q)
- **Window memory** — remembers size and position between launches
- **External links** — open in your default browser

## Requirements

- macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`)

## Build & Run

```sh
make        # build the app
make run    # build and launch
make clean  # remove build artifacts
```

## Install

```sh
make install  # copies Messenger.app to /Applications
```

## Project Structure

```
Sources/main.swift  — app delegate, WKWebView setup, notification bridge, cookie persistence
Info.plist          — bundle config, camera/mic usage descriptions
AppIcon.icns        — dock icon
Makefile            — build system
```
