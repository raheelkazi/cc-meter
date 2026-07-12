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

Commit and push. Pushing the updated tap formula is the release step that
automatic clients observe on their next due check. Clients older than v0.4.3,
clients with automatic updates disabled, and clients not running as the
Homebrew service still get it with `brew update && brew upgrade cc-meter`.

(Alternatively `brew bump-formula-pr` automates the url/sha256 bump.)
