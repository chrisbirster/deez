class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.4.2"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.4.2/deez-aarch64-apple-darwin.tar.gz"
    sha256 "cb8c4642d0e32d3ac3644e9fa36e8a0835fce6c837fd7ff412d0554af1b71fac"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.4.2/deez-x86_64-apple-darwin.tar.gz"
    sha256 "cb4535a2ca00a599cd642059c709e7ef16fb9c1ff42b414c3f77857ebecf5059"
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
