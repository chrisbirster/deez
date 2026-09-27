class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.7"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.7/deez-aarch64-apple-darwin.tar.gz"
    sha256 "ecce88d52950898ed240931da44dba2150fa2265b81636a1494bf81a5472ee2c"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.7/deez-x86_64-apple-darwin.tar.gz"
    sha256 "769141725adf1935202dbe4765a05043f1317a7a96a131ed47a99f7613670bbe"
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
