class Ginbar < Formula
  desc "A custom menu bar for macOS with per-space app switching and window previews"
  homepage "https://github.com/richmidwinter/GinBar"

  # To enable stable installs, create a GitHub Release (e.g. v1.0.0) and update
  # the two lines below with the release tarball URL and its sha256:
  #
  #   url "https://github.com/richmidwinter/GinBar/archive/refs/tags/v1.0.0.tar.gz"
  #   sha256 "..."
  #
  # Then users can run: brew install ginbar
  #
  # Until then, install from the latest source with:
  #   brew install --HEAD ginbar
  head "https://github.com/richmidwinter/GinBar.git", branch: "master"

  depends_on macos: :ventura
  depends_on xcode: [":build"]

  def install
    system "xcodebuild",
           "-project", "GinBar.xcodeproj",
           "-scheme", "GinBar",
           "-configuration", "Release",
           "SYMROOT=build",
           "CODE_SIGNING_REQUIRED=NO",
           "CODE_SIGN_IDENTITY="

    prefix.install "build/Release/GinBar.app"
  end

  def caveats
    <<~EOS
      GinBar.app has been installed to:
        #{opt_prefix}/GinBar.app

      To use it, symlink it into your Applications folder:
        ln -sf #{opt_prefix}/GinBar.app /Applications/GinBar.app

      Then launch it from Launchpad, Spotlight, or Finder.
    EOS
  end
end
