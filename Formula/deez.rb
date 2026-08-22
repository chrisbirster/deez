class Deez < Formula
  desc "Terminal-first spaced-repetition system using FSRS"
  homepage "https://github.com/chrisbirster/deez"
  version "0.1.1"
  license "MIT"

  on_arm do
    url "https://github.com/chrisbirster/deez/releases/download/v0.1.1/deez-aarch64-apple-darwin.tar.gz"
    sha256 "2184386e4fc9bbb561b44092e2a16684d4f83c505a060316926e78c014384f29"
  end

  on_intel do
    url "https://github.com/chrisbirster/deez/releases/download/v0.1.1/deez-x86_64-apple-darwin.tar.gz"
    sha256 "b068166483159fe8f84490c0df44f398304cf1ac906d5b6ddd4ca2ddc9af4fa9"
  end

  depends_on :macos

  def install
    bin.install "deez"
  end

  test do
    assert_match "DEEZ", shell_output("#{bin}/deez --help")
  end
end
