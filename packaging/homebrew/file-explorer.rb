# typed: strict
# frozen_string_literal: true

cask "file-explorer" do
  version "1.2.0"
  sha256 :no_check # replace with the real checksum of the release zip

  url "https://github.com/file-explorer-mac/file-explorer-mac/releases/download/v#{version}/File-Explorer-#{version}-universal.zip",
      verified: "github.com/file-explorer-mac/file-explorer-mac/"
  name "File Explorer"
  desc "Native, tabbed file manager in the style of Windows Explorer"
  homepage "https://github.com/file-explorer-mac/file-explorer-mac"

  depends_on macos: :ventura

  app "File Explorer.app"

  zap trash: [
    "~/Library/Application Support/File Explorer",
    "~/Library/Caches/com.fileexplorer.app",
    "~/Library/HTTPStorages/com.fileexplorer.app",
    "~/Library/Preferences/com.fileexplorer.app.plist",
    "~/Library/Saved Application State/com.fileexplorer.app.savedState",
  ]
end
