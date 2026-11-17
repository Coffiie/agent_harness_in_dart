# coding_agent_in_dart

A coding agent harness written in Dart, with a terminal UI and a phone app to drive it.

## Layout

```
core/       the agent without a UI: the loop, model providers (Gemini, ChatGPT),
            tools, sessions, orchestration, the sandbox, the phone link's server,
            and the design system (palettes and Term's faces)
tui/        the terminal UI, built with nocterm on core
phone_app/  the Flutter app that drives the TUI from a phone, on core's design system
docs/       the demo GIFs the pull requests show
```

`tui` and `phone_app` depend on `core` by path. `core` has no UI library in it, so both can use it: each turns core's palette into its own colors.

## Run it

```
cd tui
dart run coding_agent_in_dart            # Gemini, with GEMINI_API_KEY set
dart run coding_agent_in_dart --chatgpt  # your ChatGPT plan
```

`cd core && dart run coding_agent_core:cli` runs the first plain CLI, without the TUI.

## Tests

```
cd core && dart test
cd tui && dart test
cd phone_app && flutter test
```
