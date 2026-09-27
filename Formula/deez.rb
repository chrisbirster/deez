class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.6"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.6/deez-aarch64-apple-darwin.tar.gz"
    sha256 "517f37f1146d50bd16dfa80d8d899ad2cd59306348c568d557412d099f4b18b1"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.6/deez-x86_64-apple-darwin.tar.gz"
    sha256 "81e1c1fca4c7780fc8718979c499abc0cba75af8830447abc969ff656e4ffe7d"
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
