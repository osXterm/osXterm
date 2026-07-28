cask "osxterm" do
  version "0.1.0"
  sha256 "0ef7446c51b05a864d119e8b624b7631846b02741fbbfc7cadbaf64a1e18546e"

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
