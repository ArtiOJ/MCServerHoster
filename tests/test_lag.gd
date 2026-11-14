extends TestCase

const SS_OUTPUT := "0      1018   [::ffff:192.168.4.22]:2314  [::ffff:47.7.172.149]:64464\n\t cubic wscale:8,10 rto:260 rtt:59.626/6.791 ato:44 mss:1460 pmtu:1500 rcvmss:850 advmss:1460 cwnd:148 ssthresh:148 bytes_sent:18980408 bytes_retrans:38569 bytes_acked:18940821 bytes_received:291201 segs_out:41273 segs_in:33844 data_segs_out:32328 data_segs_in:24997 send 28991380bps lastsnd:1 lastrcv:1 lastack:1 pacing_rate 34789144bps delivery_rate 30081896bps delivered:32296 app_limited busy:318734ms unacked:6 retrans:0/27 rcv_rtt:70456.4 rcv_space:66202 rcv_ssthresh:64076 minrtt:39.904 snd_wnd:261632 rcv_wnd:64512\n0      1492   [::ffff:192.168.4.22]:2314 [::ffff:96.63.145.140]:57499\n\t cubic wscale:8,10 rto:277 rtt:76.41/3.044 ato:40 mss:1460 bytes_sent:39583017 bytes_acked:39521794 segs_out:79966 lastrcv:27 lastack:27 retrans:0/51 minrtt:55.891\n"


func test_parse_ss() -> void:
	var conns := LagAnalysis.parse_ss(SS_OUTPUT)
	check_eq(conns.size(), 2, "two connections")
	var a: Dictionary = conns[0]
	check_eq(a.host, "47.7.172.149", "IPv4-mapped peer unwrapped")
	check_eq(a.port, 64464, "peer port")
	check_eq(a.q, 1018, "send queue")
	check(is_equal_approx(float(a.rtt), 59.626), "rtt")
	check(is_equal_approx(float(a.rtt_var), 6.791), "rtt variance")
	check(is_equal_approx(float(a.minrtt), 39.904), "min rtt")
	check_eq(int(a.lastrcv), 1, "last receive")
	check_eq(int(a.retrans_total), 27, "total retransmits")
	check_eq(int(a.segs_out), 41273, "segments out")
	check_eq(conns[1].port, 57499, "second connection")


func test_parse_addresses() -> void:
	check_eq(LagAnalysis.split_address("[2001:db8::1]:5555"), ["2001:db8::1", 5555], "IPv6")
	check_eq(LagAnalysis.split_address("/96.63.145.140:50592"), ["96.63.145.140", 50592], "Java style")
	var login := LagAnalysis.parse_login("[20:05:17] [Server thread/INFO]: FirestormMCYT[/96.63.145.140:57499] logged in with entity id 55755 at ([minecraft:the_nether]78.6, 15.0, 194.6)")
	check_eq(login.get("name"), "FirestormMCYT", "login name")
	check_eq(login.get("port"), 57499, "login port")


func test_parse_mspt_and_ping() -> void:
	var m := LagAnalysis.parse_mspt("§6Server tick times §e(§7avg§e/§7min§e/§7max§e)§6 from last 5s§7,§6 10s§7,§6 1m§e:\n§6◴ §a4.4§7/§a1.8§7/§a33.3§e, §a4.6§7/§a1.8§7/§a33.3§e, §a5.5§7/§a0.3§7/§c219.3\n")
	check(is_equal_approx(float(m.get("avg", 0)), 4.4), "5 s average")
	check(is_equal_approx(float(m.get("max", 0)), 33.3), "5 s max")
	check(is_equal_approx(float(m.get("max_1m", 0)), 219.3), "1 min max")
	check(LagAnalysis.parse_mspt("Unknown command").is_empty(), "not Paper")
	check(is_equal_approx(LagAnalysis.parse_ping("64 bytes from 192.168.4.1: icmp_seq=1 ttl=64 time=1.38 ms"), 1.38), "linux ping")
	check(is_equal_approx(LagAnalysis.parse_ping("Reply from 192.168.4.1: bytes=32 time<1ms TTL=64"), 1.0), "windows ping")
	check_eq(LagAnalysis.parse_ping("1 packets transmitted, 0 received, 100% packet loss"), -1.0, "lost")


func test_parse_disconnects() -> void:
	var d := LagAnalysis.parse_disconnect("[20:07:38] [Server thread/INFO]: FireBall11901 was kicked due to keepalive timeout!")
	check_eq(d.get("kind"), "timeout", "keepalive kick")
	check_eq(d.get("name"), "FireBall11901", "keepalive name")
	check_eq(LagAnalysis.parse_disconnect("[20:08:08] [Server thread/INFO]: FireBall11901 lost connection: Timed out").get("kind"), "timeout", "timed out")
	d = LagAnalysis.parse_disconnect("[17:24:40] [Server thread/INFO]: FirestormMCYT (/96.63.145.140:54271) lost connection: Disconnected")
	check_eq(d.get("kind"), "quit", "normal quit with address")
	check_eq(d.get("name"), "FirestormMCYT", "quit name")
	check_eq(LagAnalysis.parse_disconnect("[1:00:00] [Server thread/INFO]: Bob lost connection: Internal Exception: java.net.SocketException: Connection reset").get("kind"), "reset", "reset")
	check_eq(LagAnalysis.parse_disconnect("[18:56:06] [Server thread/INFO]: FirestormMCYT lost connection: Flying is not enabled on this server").get("kind"), "kick", "kick")
	check_eq(LagAnalysis.parse_behind("[12:00:00] [Server thread/WARN]: Can't keep up! Is the server overloaded? Running 5012ms or 100 ticks behind"), 5012, "can't keep up")


func _sample(t: float, players: Dictionary, gw := 3.0, net := 18.0) -> Dictionary:
	return {"t": t, "gw": gw, "net": net, "up": 250000, "p": players}


func _ticks(n: int, worst := 20.0) -> Array:
	var out: Array = []
	for i in n:
		out.append({"t": float(i * 5), "avg": 5.0, "max": worst, "rcon": 2})
	return out


func test_judge_single_player_timeout_is_their_connection() -> void:
	var samples: Array = []
	for i in 20:
		var quiet := 0 if i < 5 else (i - 5) * 2000
		samples.append(_sample(i * 2.0, {
			"FireBall11901": {"rtt": 60.0, "min": 40.0, "quiet": quiet},
			"FirestormMCYT": {"rtt": 76.0, "min": 56.0, "quiet": 20},
		}))
	var j := LagAnalysis.judge_player("FireBall11901", "timeout", samples, _ticks(8))
	check_eq(j.verdict, LagAnalysis.VERDICT_PLAYER, "only this player went quiet")


func test_judge_everyone_quiet_is_server_network() -> void:
	var samples: Array = []
	for i in 10:
		var quiet := 0 if i < 3 else 8000
		samples.append(_sample(i * 2.0, {"A": {"rtt": 50.0, "min": 40.0, "quiet": quiet}, "B": {"rtt": 70.0, "min": 60.0, "quiet": quiet}}))
	check_eq(LagAnalysis.judge_player("A", "timeout", samples, _ticks(4)).verdict, LagAnalysis.VERDICT_NETWORK, "all players at once")


func test_judge_router_loss_is_server_network() -> void:
	var samples: Array = []
	for i in 9:
		samples.append(_sample(i * 2.0, {"A": {"rtt": 50.0, "min": 40.0, "quiet": 6000}}, -1.0 if i % 2 == 0 else 3.0))
	check_eq(LagAnalysis.judge_player("A", "timeout", samples, _ticks(4)).verdict, LagAnalysis.VERDICT_NETWORK, "router pings lost")


func test_judge_freeze_is_server() -> void:
	var samples: Array = [_sample(0.0, {"A": {"rtt": 50.0, "min": 40.0, "quiet": 10}})]
	var ticks := _ticks(4)
	ticks.append({"t": 20.0, "rcon": -1})
	check_eq(LagAnalysis.judge_player("A", "timeout", samples, ticks).verdict, LagAnalysis.VERDICT_SERVER, "server stopped answering")
	check_eq(LagAnalysis.tick_trouble({"avg": 5.0, "max": 300.0, "rcon": 2}), "hitch", "visible hitch")
	check_eq(LagAnalysis.tick_trouble({"avg": 5.0, "max": 40.0, "rcon": 2}), "", "normal tick")
	check_eq(LagAnalysis.tick_trouble({"avg": 60.0, "max": 90.0, "rcon": 2}), "slow", "below 20 TPS")


func test_judge_timeout_while_player_still_sending_is_server() -> void:
	var samples: Array = []
	for i in 20:
		samples.append(_sample(i * 2.0, {"A": {"rtt": 50.0, "min": 40.0, "quiet": 30}, "B": {"rtt": 60.0, "min": 50.0, "quiet": 20}}))
	check_eq(LagAnalysis.judge_player("A", "timeout", samples, _ticks(8)).verdict, LagAnalysis.VERDICT_SERVER, "packets kept arriving")
	check_eq(LagAnalysis.judge_player("A", "reset", samples, _ticks(8)).verdict, LagAnalysis.VERDICT_PLAYER, "a reset comes from their side")


func test_player_trouble_thresholds() -> void:
	check_eq(LagAnalysis.player_trouble({"rtt": 60.0, "min": 40.0, "quiet": 30}), "", "healthy")
	check_eq(LagAnalysis.player_trouble({"rtt": 400.0, "min": 40.0, "quiet": 30}), "spike", "spike")
	check_eq(LagAnalysis.player_trouble({"rtt": 180.0, "min": 20.0, "quiet": 30}), "", "high but under the floor")
	check_eq(LagAnalysis.player_trouble({"rtt": 60.0, "min": 40.0, "quiet": 6000}), "quiet", "silent")
	check_eq(LagAnalysis.player_trouble({"rtt": 60.0, "min": 40.0, "quiet": 30, "loss": 8.0}), "loss", "loss")


func test_report_text() -> void:
	var inc := {"t": 1000.0, "title": "Bob timed out", "verdict": LagAnalysis.VERDICT_PLAYER, "summary": "Only Bob.", "evidence": ["Bob: ping 60 ms."]}
	var text := LagAnalysis.report("Test", [inc], 3600, 1500.0)
	check(text.contains("1 incident (1 player's connection)"), "summary line: " + text)
	check(text.contains("• Bob: ping 60 ms."), "evidence included")
