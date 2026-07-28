cask "osxterm" do
  version "0.1.0"
  sha256 "b5bbb598f990fbe8f94231a3b15562a1e20ce7871c71301c3916484237c4e7ca"

  url "https://github.com/osXterm/osXterm/releases/download/v#{version}/osXterm-#{version}.zip"
  name "osXterm"
  desc "Native macOS SSH terminal with Ghostty and SFTP"
  homepage "https://github.com/osXterm/osXterm"

  depends_on macos: :tahoe

  app "osXterm.app"

  zap trash: [
    "~/.config/osXterm",
    "~/Library/Preferences/com.one393.osXterm.plist"
  ]
end
