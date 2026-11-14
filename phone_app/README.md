# Harness Phone

A Flutter app that controls the coding agent TUI from your phone. It shows every session with its Term, streams each chat as it happens, diffs included, sends prompts, and answers the model's askUser questions with the recommended answer already picked.

## Run it

1. Start the TUI on your computer (`dart run` in `tui/`) and type `/phone`. It shows this computer's address and a six-digit code.
2. Put the phone on the same Wi-Fi as the computer, or on the same Tailscale network.
3. Run the app: `flutter run` in this folder, with a phone or simulator connected.
4. Type the address and the code, and tap Connect.

The code changes every time the TUI starts the server, and five wrong codes stop it until you type `/phone` again.

## Tests

`flutter test` runs the widget tests against a fake TUI. The connection itself is tested from the CLI's side, in `core/test/phone_test.dart`.

The colors and Term's faces come from `core`'s design system (`package:coding_agent_core/design_system.dart`), the same ones the TUI draws.
