cask "prtray" do
  version "1.0.0"
  sha256 "REPLACED_BY_RELEASE_SCRIPT"

  url "https://github.com/Akkikens/prtray/releases/download/v#{version}/PRTray.dmg"
  name "PRTray"
  desc "Graphite-style GitHub PR tray for the menu bar"
  homepage "https://github.com/Akkikens/prtray"

  depends_on macos: ">= :sonoma"

  app "PRTray.app"

  zap trash: [
    "~/Library/Preferences/com.akkikens.prtray.plist",
  ]
end
