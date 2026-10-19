extends TestCase
## Windows logic that can be checked on any OS: the launcher batch file, core masks,
## firewall verdicts and toast text.


func test_launch_script() -> void:
	var argv := PackedStringArray(["C:/Program Files/Java/bin/java.exe", "-Xmx4096M", "-jar", "paper.jar", "--nogui"])
	var plain := WindowsBackend.launch_script("C:/Users/Me/Minecraft Servers/survival", argv, 0, 0)
	var lines := plain.split("\r\n")
	check_eq(lines[2], "cd /d \"C:\\Users\\Me\\Minecraft Servers\\survival\"", "changes into the server folder (backslashes, quoted)")
	check_eq(lines[3], "\"C:/Program Files/Java/bin/java.exe\" \"-Xmx4096M\" \"-jar\" \"paper.jar\" \"--nogui\"", "every argument quoted")
	check(plain.ends_with("exit /b %ERRORLEVEL%\r\n"), "passes Java's exit code on")
	var limited := WindowsBackend.launch_script("C:/s", argv, 12, 0b1010).split("\r\n")[3]
	check(limited.begins_with("start \"\" /b /wait /low /affinity a "), "priority and cores through start: " + limited)
	check(WindowsBackend.launch_script("C:/s", argv, 3, 0).split("\r\n")[3].contains("/belownormal"), "mild priority")


func test_batch_quote() -> void:
	check_eq(WindowsBackend.batch_quote("100%"), "\"100%%\"", "percent doubled")
	check_eq(WindowsBackend.batch_quote("a\"b & c"), "\"ab & c\"", "quotes dropped, & kept inside quotes")


func test_affinity_mask() -> void:
	check_eq(WindowsBackend.affinity_mask("0-3", 16), 0b1111, "range")
	check_eq(WindowsBackend.affinity_mask("0,2,4", 16), 0b10101, "list")
	check_eq(WindowsBackend.affinity_mask("6-9", 8), 0b11000000, "clamped to existing cores")
	check_eq(WindowsBackend.affinity_mask("", 8), 0, "empty = no pinning")


func test_windows_firewall_verdict() -> void:
	check_eq(NetworkService.windows_port_verdict("port|Minecraft", 25565).allowed, "yes", "port rule")
	check_eq(NetworkService.windows_port_verdict("java|Java(TM) Platform SE binary", 25565).allowed, "yes", "Java program rule")
	check_eq(NetworkService.windows_port_verdict("none|", 25565).allowed, "no", "no rule")
	check_eq(NetworkService.windows_port_verdict("", 25565).allowed, "unknown", "no answer")


func test_toast_script_escapes() -> void:
	var script := Notifier.windows_toast_script("Survival", "Bob's <server> & co")
	check(script.contains("Bob&apos;s &lt;server&gt; &amp; co"), "XML-escaped, so no quote reaches PowerShell")
