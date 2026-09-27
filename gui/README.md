# Mimi GUI

Open `Mimi/Mimi.xcodeproj` in Xcode and run the Mimi scheme. It needs Xcode 26
or later (Swift 6.2). Keep the project format at Xcode 16 (object version 77)
in the File inspector: CI builds with the newest Xcode on GitHub's runners,
which cannot open a newer format.

## Signing

Signing settings live in `Mimi/Config/Signing.xcconfig`. The team id is
personal and not committed: copy `Mimi/Config/Local.xcconfig.example` to
`Mimi/Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` there.

## Tests

From the repository root, the same command CI runs:

```
xcodebuild -project gui/Mimi/Mimi.xcodeproj -scheme Mimi \
  -destination 'platform=macOS' -only-testing:MimiTests \
  CODE_SIGNING_ALLOWED=NO test
```
