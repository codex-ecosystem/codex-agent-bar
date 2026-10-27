<div align="center">
    <h1>Codex Agent Bar</h1>
</div>
<div align="center">
    <img src="http://github.com/lonewolfyx/codex-agent-bar/blob/main/screenshots.png?raw=true" alt="codex-agent-bar">
</div>

## Introduction

Codex Agent Bar is a lightweight macOS menu bar app for monitoring your Codex quota at a glance. It connects to the local `codex app-server`, reads the current account rate limit data, and displays the remaining quota directly in the system menu bar.

## Installation

On Apple Silicon with macOS 13 or later:

```sh
brew install --cask codex-ecosystem/tap/codex-agent-bar
open -a AgentBar
```

Agent Bar needs an available, signed-in Codex installation.

Agent Bar locates the CLI by running `which codex` in your login interactive shell and reuses that shell's PATH when checking the CLI version and starting the app server, so package-manager shims can also find Node.js. If the shell lookup fails or times out, it checks the CLI bundled with the Codex or ChatGPT app.

## Features

- Shows Codex quota in the macOS menu bar.
- Displays short-term and long-term quota windows, including the 5-hour and 1-week windows when available.
- Uses color-coded quota status to make low remaining usage easy to notice.
- Provides a compact popover with quota progress, reset times, last updated time, and a quit action.
- Refreshes quota data automatically every 30 seconds.
- Checks for AgentBar updates on launch and hourly while running, with a manual check available from the version in the popover footer.
- Runs as a menu bar accessory app without appearing in the Dock.

[LICENSE](LICENSE) &copy; [lonewolfyx](https://github.com/lonewolfyx)
