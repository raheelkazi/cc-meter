# Homebrew Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let anyone with Homebrew install and run cc-meter with `brew install raheelkazi/tap/cc-meter && brew services start cc-meter`, no git clone or Xcode project required.

**Architecture:** A Homebrew formula that builds cc-meter from a tagged source tarball (`swift build -c release`) and installs the binary, with a `service` block so `brew services` runs it as a per-user menu bar LaunchAgent. The formula lives in a separate public tap repo `raheelkazi/homebrew-tap`; the cc-meter repo gains a LICENSE, a README install section, and a release runbook.

**Tech Stack:** Homebrew (Ruby formula DSL), Swift Package Manager, git/GitHub (`gh` CLI), GitHub source tarballs.

## Global Constraints

- Distribution audience is developer-ish; free path only (no Apple Developer account, no signing/notarization, no `.app` bundle, no hosted binaries).
- Formula builds from source: `swift build --disable-sandbox -c release`, then `bin.install ".build/release/cc-meter"`.
- Persistence via Homebrew `service` block (per-user agent): `keep_alive false` (the popover Quit must work), `run_at_load true`.
- First release tag: `v0.1.0`. Tap repo: `raheelkazi/homebrew-tap` (invoked as `raheelkazi/tap`).
- License: MIT, copyright holder "Raheel Kazi", year 2026.
- Style: no em dashes anywhere (code, comments, docs). Regular hyphens only.
- Git workflow: cc-meter changes go on branch `feat/homebrew-distribution` and merge to `main` via PR before tagging; never commit cc-meter changes directly to `main`.
- Keychain access is already handled via `/usr/bin/security`; do not change it.

## File Structure

```
# In the cc-meter repo (branch feat/homebrew-distribution):
LICENSE                 # new: MIT license text
README.md               # modify: add "Install with Homebrew" section
docs/RELEASING.md       # new: release/update runbook

# In the new, separate raheelkazi/homebrew-tap repo:
Formula/cc-meter.rb     # new: the Homebrew formula
README.md               # new: one-liner describing the tap
```

---

### Task 1: Repo prep (LICENSE, README install section, release runbook)

Everything the tagged source tarball must contain. All on branch
`feat/homebrew-distribution` in `/Users/raheelkazi/Desktop/Speechify/cc-meter`.

**Files:**
- Create: `LICENSE`
- Modify: `README.md`
- Create: `docs/RELEASING.md`

**Interfaces:**
- Produces: a tagged commit (later, Task 2) whose tarball includes LICENSE, so
  the formula's `license "MIT"` is accurate and `brew audit --strict` passes.

- [ ] **Step 1: Confirm you are on the feature branch**

Run: `cd /Users/raheelkazi/Desktop/Speechify/cc-meter && git branch --show-current`
Expected: `feat/homebrew-distribution` (created during brainstorming). If not,
`git checkout feat/homebrew-distribution`.

- [ ] **Step 2: Create the LICENSE file**

`LICENSE`:

```
MIT License

Copyright (c) 2026 Raheel Kazi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Add the "Install with Homebrew" section to README.md**

In `README.md`, immediately after the intro paragraph that ends with "No token
is ever displayed or stored elsewhere." and before the `## Requirements`
heading, insert:

```markdown
## Install with Homebrew

    brew install raheelkazi/tap/cc-meter
    brew services start cc-meter

That builds cc-meter, installs it, and runs it as a menu bar app that starts at
login. The first time it reads your usage, macOS asks to allow `security` to
access your Keychain - click "Always Allow" once and it will not ask again.

Manage it with:

    brew services restart cc-meter   # after an upgrade
    brew services stop cc-meter      # stop and disable

Upgrade later with `brew upgrade cc-meter`.
```

- [ ] **Step 4: Create the release runbook**

`docs/RELEASING.md`:

```markdown
# Releasing cc-meter

cc-meter is distributed through the Homebrew tap
[raheelkazi/homebrew-tap](https://github.com/raheelkazi/homebrew-tap). The
formula builds from a tagged source tarball, so a release is: tag a version,
then point the formula at the new tarball.

## Cut a release

1. Make sure `main` is green (`swift test`) and has everything you want to ship.
2. Tag and push:

       git checkout main && git pull
       git tag vX.Y.Z
       git push origin vX.Y.Z

3. Get the tarball sha256:

       curl -sL https://github.com/raheelkazi/cc-meter/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256

## Update the formula

In the `raheelkazi/homebrew-tap` repo, edit `Formula/cc-meter.rb`:

- Set `url` to `.../archive/refs/tags/vX.Y.Z.tar.gz`.
- Set `sha256` to the value from above.

Commit and push. Users get it with `brew update && brew upgrade cc-meter`.

(Alternatively `brew bump-formula-pr` automates the url/sha256 bump.)
```

- [ ] **Step 5: Verify the app still builds clean (nothing here touches source, but confirm)**

Run: `swift build -c release 2>&1 | tail -1`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add LICENSE README.md docs/RELEASING.md
git commit -m "docs: add LICENSE, Homebrew install section, and release runbook"
```

---

### Task 2: Merge to main and tag v0.1.0

Turn the feature branch into a `v0.1.0` release whose tarball the formula pins.

**Files:** none (git/GitHub operations only).

**Interfaces:**
- Consumes: the Task 1 commit (LICENSE etc.).
- Produces: a `v0.1.0` tag on `main` and its tarball sha256, consumed by the
  formula in Task 3.

- [ ] **Step 1: Push the feature branch and open a PR**

```bash
git push -u origin feat/homebrew-distribution
gh pr create --title "Homebrew distribution: LICENSE, README install, release runbook" \
  --body "Adds MIT LICENSE, a Homebrew install section, and a release runbook, in preparation for the raheelkazi/homebrew-tap formula. See docs/superpowers/specs/2026-07-06-homebrew-distribution-design.md." \
  --base main
```
Expected: a PR URL is printed.

- [ ] **Step 2: Merge the PR to main**

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull
```
Expected: `main` now contains LICENSE, the README section, and docs/RELEASING.md.
Verify: `ls LICENSE && grep -q "Install with Homebrew" README.md && echo OK`

- [ ] **Step 3: Tag and push v0.1.0**

```bash
git tag v0.1.0
git push origin v0.1.0
```
Expected: `git ls-remote --tags origin | grep v0.1.0` shows the tag.

- [ ] **Step 4: Compute and record the tarball sha256**

```bash
curl -sL https://github.com/raheelkazi/cc-meter/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
```
Expected: a 64-hex-character sha256 followed by ` -`. Record this value; Task 3
puts it in the formula. (GitHub generates this tarball deterministically from the
tag, so the value is stable.)

---

### Task 3: Create the Homebrew tap repo and formula

A separate public repo `raheelkazi/homebrew-tap` with the formula.

**Files:**
- Create (in the tap repo): `Formula/cc-meter.rb`
- Create (in the tap repo): `README.md`

**Interfaces:**
- Consumes: the `v0.1.0` tarball URL and sha256 from Task 2.
- Produces: an installable formula reachable as `raheelkazi/tap/cc-meter`.

- [ ] **Step 1: Create and clone the tap repo**

```bash
cd /Users/raheelkazi/Desktop/Speechify
gh repo create raheelkazi/homebrew-tap --public \
  --description "Homebrew tap for cc-meter" --clone
cd homebrew-tap
mkdir -p Formula
```
Expected: the repo is created and cloned into
`/Users/raheelkazi/Desktop/Speechify/homebrew-tap`.

- [ ] **Step 2: Write the formula**

`Formula/cc-meter.rb` (replace `PUT_SHA256_HERE` with the value from Task 2 Step 4):

```ruby
class CcMeter < Formula
  desc "macOS menu bar app showing your Claude Code usage limits"
  homepage "https://github.com/raheelkazi/cc-meter"
  url "https://github.com/raheelkazi/cc-meter/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PUT_SHA256_HERE"
  license "MIT"

  depends_on :macos
  depends_on xcode: :build

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/cc-meter"
  end

  service do
    run [opt_bin/"cc-meter"]
    keep_alive false
    run_at_load true
    log_path var/"log/cc-meter.log"
    error_log_path var/"log/cc-meter.log"
  end

  test do
    assert_predicate bin/"cc-meter", :executable?
  end
end
```

- [ ] **Step 3: Write the tap README**

`README.md` (in the tap repo):

```markdown
# homebrew-tap

Homebrew tap for [cc-meter](https://github.com/raheelkazi/cc-meter), a macOS
menu bar app showing your Claude Code usage limits.

    brew install raheelkazi/tap/cc-meter
    brew services start cc-meter
```

- [ ] **Step 4: Commit and push the tap**

```bash
git add Formula/cc-meter.rb README.md
git -c user.name="Raheel Kazi" -c user.email="raheelka@gmail.com" \
  commit -m "cc-meter 0.1.0"
git push
```
Expected: the tap repo on GitHub contains `Formula/cc-meter.rb`.

---

### Task 4: End-to-end verification

Prove the published install path works, then leave the machine clean.

**Files:** none (verification only).

**Interfaces:**
- Consumes: the pushed tap and formula from Task 3.

- [ ] **Step 1: Tap and audit the formula**

```bash
brew tap raheelkazi/tap
brew audit --strict raheelkazi/tap/cc-meter
```
Expected: `brew audit` reports no problems. If it flags the `service` block,
`xcode` dependency, or `desc` wording, fix `Formula/cc-meter.rb` in the tap repo,
push, `brew update`, and re-run. (Note if you had to change the formula.)

- [ ] **Step 2: Install from the tap (build from source)**

```bash
brew install raheelkazi/tap/cc-meter
```
Expected: Homebrew downloads the v0.1.0 tarball, runs `swift build -c release`,
and installs `cc-meter`. `brew list cc-meter` shows the installed binary under
`$(brew --prefix)/bin/cc-meter`.

Troubleshooting to apply if it fails: if the build errors because only the Xcode
Command Line Tools are present (not full Xcode), that confirms `depends_on xcode:
:build` is correct and the user must install Xcode; if instead `swift build`
works fine without full Xcode in your environment, that is expected and the
install succeeds. Report which occurred.

- [ ] **Step 3: Start it as a service and confirm it runs**

```bash
brew services start cc-meter
sleep 3
brew services info cc-meter
pgrep -xl cc-meter
```
Expected: `brew services info` shows it running (loaded, a PID), and `pgrep`
lists the process. The menu bar item should appear (colored dot + percent).
Confirm visually.

- [ ] **Step 4: Clean up the verification install**

```bash
brew services stop cc-meter
brew uninstall cc-meter
pgrep -xl cc-meter || echo "stopped and removed"
```
Expected: the service stops, the binary is removed, no `cc-meter` process
remains.

Note: this leaves the manually-installed LaunchAgent from earlier
(`~/Library/LaunchAgents/com.raheelkazi.cc-meter.plist`) in place and untouched.
Migrating your own machine from that manual agent to the Homebrew service is
optional and out of scope for this plan; if desired, `launchctl bootout
gui/$(id -u)/com.raheelkazi.cc-meter && rm ~/Library/LaunchAgents/com.raheelkazi.cc-meter.plist`
before `brew services start`.

---

## Self-Review

**Spec coverage:**
- Two-line Homebrew install experience -> Task 3 (formula) + Task 4 (verified). Covered.
- Formula builds from source, no signing/hosting -> Task 3 Step 2 (`swift build`, source tarball url). Covered.
- `brew services` persistence, `keep_alive false` -> Task 3 Step 2 `service` block. Covered.
- Keychain unchanged -> Global Constraints; no task touches it. Covered.
- Release tag `v0.1.0` + sha256 -> Task 2. Covered.
- Tap repo `raheelkazi/homebrew-tap` -> Task 3 Step 1. Covered.
- README install section -> Task 1 Step 3. Covered.
- Release/update runbook -> Task 1 Step 4 (docs/RELEASING.md). Covered.
- LICENSE (MIT) before the tag -> Task 1 Step 2, tagged in Task 2. Covered.
- `brew audit` passes -> Task 4 Step 1. Covered.
- Feature-branch-then-PR workflow -> Task 2 Steps 1-2. Covered.

**Placeholder scan:** The formula's `PUT_SHA256_HERE` is an intentional handoff
from Task 2 Step 4 (the value is computed at execution time from the real tag),
not a vague placeholder - the exact command that produces it is specified. No
other TBD/TODO or vague steps.

**Type consistency:** The tarball URL
`https://github.com/raheelkazi/cc-meter/archive/refs/tags/v0.1.0.tar.gz` is
identical in Task 2 Step 4 (sha256 computation) and Task 3 Step 2 (formula
`url`). The tap name `raheelkazi/homebrew-tap` / invocation `raheelkazi/tap` is
consistent across Tasks 3 and 4 and the README. Formula class `CcMeter` matches
the `cc-meter` file/binary name per Homebrew's naming rule.
