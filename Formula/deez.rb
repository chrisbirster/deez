class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.3"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.3/deez-aarch64-apple-darwin.tar.gz"
    sha256 "dc2311f27f307eed29f270d84c3590cc06a7f43e1bbb582711bb00a40f822f55"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.3/deez-x86_64-apple-darwin.tar.gz"
    sha256 "c6de5e84e6123208fbcf4ebdb21997f5e07351086c6c791daa61b95d3a59454c"
  end

  depends_on :macos

  def install
    bin.install "deez"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
  end
end
