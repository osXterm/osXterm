cask "osxterm" do
  version "0.1.0"
  sha256 "7c053fd0d92d422dbfa5393035f8bc86711bfb79c23f2c18015aa0c2db0c602a"

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
