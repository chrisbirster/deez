class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.8"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.8/deez-aarch64-apple-darwin.tar.gz"
    sha256 "13f7de83705e3c04c5d387c7dc0be1cd868858c49a577ec64cf7cb4f80c8275e"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.8/deez-x86_64-apple-darwin.tar.gz"
    sha256 "0df8d516fb764f2afdc38c270780cf98262bb0adfcc115ab6755a4ea1575db97"
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
