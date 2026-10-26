-- dmg_window_layout.applescript
-- 一次性工具：给挂载中的 cute pet.dmg 设置标准安装窗口（窗口尺寸 / 图标位置 / 背景图 / 箭头引导）
-- 生成后的 .DS_Store 由 release.sh 复用（见 packaging/dmg.dsstore），日常发版无需再跑本脚本
--
-- 用法：
--   1) hdiutil create -srcfolder <stage> -fs HFS+ -format UDRW -volname "cute pet" /tmp/layout.dmg
--   2) hdiutil attach /tmp/layout.dmg
--   3) osascript packaging/dmg_window_layout.applescript
--   4) cp "/Volumes/cute pet/.DS_Store" packaging/dmg.dsstore && hdiutil detach "/Volumes/cute pet"
--   5) hdiutil convert /tmp/layout.dmg -format UDZO -o <final.dmg>

tell application "Finder"
  tell disk "cute pet"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- 内容区 660x420，外加 28pt 标题栏
    set the bounds of container window to {100, 100, 760, 548}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set text size of vo to 12
    set position of item "cute pet.app" of container window to {165, 210}
    set position of item "Applications" of container window to {495, 210}
    try
      set background picture of vo to (file ".background:dmg-background.png")
      set bgResult to "bg=file-relative"
    on error e1
      try
        set background picture of vo to ((POSIX file "/Volumes/cute pet/.background/dmg-background.png") as alias)
        set bgResult to "bg=posix-alias"
      on error e2
        set bgResult to "bg=FAILED " & (e1 as text) & " | " & (e2 as text)
      end try
    end try
    update without registering applications
    delay 1
    close
  end tell
end tell
return "LAYOUT_OK " & bgResult
