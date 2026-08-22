class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.1"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.1/deez-aarch64-apple-darwin.tar.gz"
    sha256 "54204b6845b5c9a11f145cfa42229c9700bc847c003f9c1583ecc5d0d87813c4"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.1/deez-x86_64-apple-darwin.tar.gz"
    sha256 "240e6907c96094360f7d36203fc5826998eb7fc09c4306308a0427c70f5ea9c2"
  end

  depends_on :macos

  def install
    bin.install "deez"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
  end
end
