# The zslice command line tool. packaging/homebrew/tap.sh in the zslice
# repository writes this file for each release.
class Zslice < Formula
  desc "Slicer for FDM 3D printers (command-line tool)"
  homepage "https://zslice.beetlebug.org/"
  license "AGPL-3.0-or-later"

  on_macos do
    on_arm do
      url "https://github.com/beetlebugorg/zslice/releases/download/v0.5.0-beta/zslice-0.5.0-beta-aarch64-macos.tar.gz"
      sha256 "48f5388e3727554f4012965d56149a96674eaa7403d8597b15ad892bd328390e"
    end
    on_intel do
      url "https://github.com/beetlebugorg/zslice/releases/download/v0.5.0-beta/zslice-0.5.0-beta-x86_64-macos.tar.gz"
      sha256 "325f4d6c8b8d25a76632595a563c289c097489cf7c96dad0f2bb4b435cc39cea"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/beetlebugorg/zslice/releases/download/v0.5.0-beta/zslice-0.5.0-beta-aarch64-linux-musl.tar.gz"
      sha256 "eb2cdbbed8fa843a63a759cc02121f7e0197fa1888b1b262e09707fc122877d3"
    end
    on_intel do
      url "https://github.com/beetlebugorg/zslice/releases/download/v0.5.0-beta/zslice-0.5.0-beta-x86_64-linux-musl.tar.gz"
      sha256 "8939e23ba98d574017689b6e0bdcda3056f7c5df5e0f475627822ed3eba27b00"
    end
  end

  def install
    bin.install "zslice"
  end

  test do
    system bin/"zslice", "demo", testpath/"demo.stl"
    system bin/"zslice", "slice", testpath/"demo.stl", "-o", testpath/"demo.gcode"
    assert_match ";LAYER:", (testpath/"demo.gcode").read
  end
end
