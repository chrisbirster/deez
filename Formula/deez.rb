class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.2.0-rc.2"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.2/deez-aarch64-apple-darwin.tar.gz"
    sha256 "4998ffd6d70bb3a3e289a23e51c51ad6c296e16ea4445405e267d9253efefe54"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.2.0-rc.2/deez-x86_64-apple-darwin.tar.gz"
    sha256 "74a3b014169e8dd10d177455c3860f00f2f79eb738cd4824038d6c810bda4f72"
  end

  depends_on :macos

  def install
    bin.install "deez"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
  end
end
