cask "prtray" do
  version "1.1.1"
  sha256 "460edca7afad1482de7aae67f9bf5e056520263e0adc9490fef943cb95a3a8cb"

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
