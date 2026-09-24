# filecoord

`filecoord` reads and replaces iCloud Drive files from scripts and AI agents through Apple's file coordination. Reads can wait for cloud-backed content; replacements let other apps save pending edits. It also works with ordinary local files. Success means the local operation finished, not that iCloud uploaded the result or another device can see it.

## Install

Requires macOS 14 or later and Swift 6 or later to build from source.

```sh
swift build -c release
install -d "$HOME/.local/bin"
install -m 755 .build/release/filecoord "$HOME/.local/bin/filecoord"
```

Add `$HOME/.local/bin` to `PATH` if it is not already present.

## Read

Write the exact file bytes to standard output:

```sh
filecoord read "$HOME/Library/Mobile Documents/com~apple~CloudDocs/report.pdf" > report.pdf
```

On failure, standard output may contain a partial file and must be discarded. Diagnostics go to standard error.

## Replace

Replace an existing file from a completed local file:

```sh
filecoord replace \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/notes.txt" \
  --from updated-notes.txt
```

Replacement guarantees the requested contents but may not preserve every extended attribute, Finder tag, ACL, or filesystem-specific metadata field. If `commit_failed` is reported, the outcome is uncertain; inspect the target before retrying. Other replacement failures leave the target unchanged.

Standard input is also accepted after it reaches EOF:

```sh
generate-notes | filecoord replace \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/notes.txt" \
  --from -
```

Empty standard input is rejected to catch broken pipelines. Supply an explicit empty file to intentionally empty the target.

Use a SHA-256 precondition to avoid replacing contents that changed since they were inspected:

```sh
filecoord read notes.txt > inspected-notes.txt
hash=$(shasum -a 256 inspected-notes.txt | cut -d ' ' -f 1)
cp inspected-notes.txt updated-notes.txt
"${EDITOR:-vi}" updated-notes.txt
filecoord replace notes.txt --from updated-notes.txt --if-match "sha256:$hash"
```

The precondition is rechecked after other apps have had a chance to save pending edits; it is not a distributed lock. Without `--if-match`, replacement is unconditional.

## Contract

Both commands operate on one existing regular file. The final path component cannot be a symbolic link, and replacement also rejects files with multiple hard links.

`--timeout SECONDS` limits each wait for coordinated access and iCloud materialization. The default is 120 seconds. Once the coordinated accessor starts, streaming and replacement are not interrupted by the timeout.

Runtime diagnostics have the form:

```text
filecoord: CODE: MESSAGE
```

The code is stable for scripts; the message is written for people. Exit statuses are:

| Status | Meaning |
| ---: | --- |
| `0` | Success |
| `1` | Operational failure |
| `3` | `--if-match` did not match |
| `64` | Invalid command usage |
| `124` | Timed out waiting for coordinated access |

Runtime codes are `invalid_target`, `invalid_source`, `not_found`, `permission_denied`, `precondition_failed`, `timed_out`, `commit_failed`, `cleanup_failed`, `read_failed`, and `replace_failed`. A `commit_failed` message identifies retained recovery data. A `cleanup_failed` diagnostic may accompany another failure and identifies staged contents that could not be removed; the primary failure determines the exit status.

## Development

Select Xcode for [command-line tools](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings) before running the test suite. CI uses Xcode 26.6.

Install the pinned development tools with [mise](https://mise.jdx.dev/):

```sh
mise install
mise run check
```

## License

MIT

iCloud Drive is a trademark of Apple Inc., registered in the U.S. and other countries and regions. This project is not affiliated with Apple.
