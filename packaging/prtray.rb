cask "prtray" do
  version "1.0.0"
  sha256 "663ade893edab11607c681be164229077700dff264eddf47e85daa118c26d692"

  url "https://github.com/Akkikens/prtray/releases/download/v#{version}/PRTray.dmg"
  name "PRTray"
  desc "Graphite-style GitHub PR tray for the menu bar"
  homepage "https://github.com/Akkikens/prtray"

  depends_on macos: :sonoma

  app "PRTray.app"

  zap trash: [
    "~/Library/Preferences/com.akkikens.prtray.plist",
  ]
end
