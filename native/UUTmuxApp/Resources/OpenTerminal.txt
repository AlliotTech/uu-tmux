-- 固定分发脚本：用参数创建 iTerm2 窗口并运行 helper。
-- argv: <helperPath> <operationUUID> [profileName]
-- 参数通过 quoted form 构造启动命令，绝不把参数插入 AppleScript 源码。
-- 返回新窗口 id（整数），供 App 关联与定位。
on run argv
	set helperPath to item 1 of argv
	set opUUID to item 2 of argv
	set launchCmd to (quoted form of helperPath) & " --request " & (quoted form of opUUID)
	tell application "iTerm2"
		if (count of argv) ≥ 3 then
			set profileName to item 3 of argv
			try
				set w to (create window with profile profileName command launchCmd)
			on error errMsg number errNum
				-- 指定 profile 缺失：回退默认，返回带标记的结果供 App 提示一次。
				set w to (create window with default profile command launchCmd)
				return "FALLBACK_DEFAULT:" & (id of w)
			end try
		else
			set w to (create window with default profile command launchCmd)
		end if
		return (id of w) as string
	end tell
end run
