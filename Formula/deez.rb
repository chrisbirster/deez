class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.5"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.5/deez-aarch64-apple-darwin.tar.gz"
    sha256 "0b4d4623c84425ef8caa72bf3fb0b904251a471420df8a9dd18e8f6ee5c77afd"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.5/deez-x86_64-apple-darwin.tar.gz"
    sha256 "eae238c097dda837ab06733a6f65bfa02c8f3e2ca478db6f6045da2a7b0f538f"
  end

  depends_on :macos

  def install
    bin.install "deez"
    (share/"deez").install "web"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
    assert_match "--web-root", shell_output("#{bin}/deez web --help")
  end
end
