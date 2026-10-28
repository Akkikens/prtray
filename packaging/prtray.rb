cask "prtray" do
  version "1.1.0"
  sha256 "876e1fca305cb73f7d70ef0623691f7f9ade082aff16ea9503bdfdde03ef1aea"

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
