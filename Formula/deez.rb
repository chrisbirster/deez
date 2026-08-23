class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.4"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.4/deez-aarch64-apple-darwin.tar.gz"
    sha256 "54338add500639a481d86bdb357eea564ab250c4f488a5e847d1ea3a94abcbd4"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.4/deez-x86_64-apple-darwin.tar.gz"
    sha256 "eba49783a5a8d0e276062004183073790da7580f7ec3b71759188f392606f5d1"
  end

  depends_on :macos

  def install
    bin.install "deez"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
  end
end
