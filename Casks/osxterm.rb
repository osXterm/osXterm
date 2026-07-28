cask "osxterm" do
  version "0.1.0"
  sha256 "5b0354f1c9f86ad62f6cdd5d13dab88d74f94acf05a06502091e7b20c3492e01"

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
