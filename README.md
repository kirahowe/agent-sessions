# Agents

A minimal native macOS app: a sidebar organizes terminal sessions under
project directories, with real [Ghostty](https://ghostty.org)-rendered
terminals (running your actual login shell) in the detail area.

## Prerequisites

- Xcode (macOS 15+ deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Babashka](https://babashka.org/): `brew install borkdude/brew/babashka`

## Usage

```sh
bb run
```

This generates the Xcode project, builds it, and launches the app. Individual
steps are also available: `bb gen`, `bb build`, `bb clean`.

The generated `macapp/Agents.xcodeproj` and build output under `macapp/.build`
are gitignored — `bb gen` regenerates the project from `macapp/project.yml`
whenever you need it.
