// SPDX-License-Identifier: MIT
/*
 * q8b-fan.c - fan control for the Radxa Dragon Q8B
 *
 * C implementation of the q8b-fan shell tool: same commands, same output,
 * but a single self-contained binary (no bash/awk/python needed).
 *
 * The fan on this board is driven by Radxa's SVC firmware service running
 * on the ADSP (rpmsg/GLINK channel RADXA_SVC_ADSP_APPS).  Linux only gets
 * a window into it through the radxa_svc_glink driver:
 *
 *   /sys/class/hwmon/hwmonN/pwm1          duty 0..255 (writable in manual mode)
 *   /sys/class/hwmon/hwmonN/pwm1_enable   0 = full, 1 = manual, 2 = auto
 *   /sys/class/platform-profile/platform-profile-0/{profile,choices}
 *   /sys/kernel/debug/radxa_svc_glink/   (files: fan_state, version, ...)
 *
 * Every read above is one rpmsg round trip (5 s timeout), so the number of
 * requests per invocation is kept small on purpose.
 *
 * Build:  make            (see the README for cross compiling)
 */

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define VERSION "1.1.0"

#define DBG_DIR   "/sys/kernel/debug/radxa_svc_glink"
#define PROF_DIR  "/sys/class/platform-profile/platform-profile-0"
#define HW_NAME   "radxa_svc_glink"
#define HWMON_GLOB "/sys/class/hwmon"

/* ------------------------------------------------------------------ output */
static const char *C_RED = "", *C_GRN = "", *C_YEL = "", *C_BLD = "", *C_OFF = "";
static const char *prog = "q8b-fan";

static void col_init(void)
{
	/* line buffering even when stdout is a pipe, so that "watch" does not
	 * lose its output when the process is killed (e.g. by timeout) */
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (isatty(STDOUT_FILENO)) {
		C_RED = "\033[31m"; C_GRN = "\033[32m"; C_YEL = "\033[33m";
		C_BLD = "\033[1m";  C_OFF = "\033[0m";
	}
}

static void die(const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "%s%s[x]%s ", C_BLD, C_RED, C_OFF);
	va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static void warnx_(const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "%s[!]%s ", C_YEL, C_OFF);
	va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
	fputc('\n', stderr);
}

static void ok(const char *fmt, ...)
{
	va_list ap;
	printf("%s[+]%s ", C_GRN, C_OFF);
	va_start(ap, fmt); vfprintf(stdout, fmt, ap); va_end(ap);
	fputc('\n', stdout);
}

static void hdr(const char *fmt, ...)
{
	va_list ap;
	printf("\n%s== ", C_BLD);
	va_start(ap, fmt); vfprintf(stdout, fmt, ap); va_end(ap);
	printf(" ==%s\n", C_OFF);
}

/* ------------------------------------------------------------------- files */
/* read a whole (small) file, trim trailing whitespace; caller frees */
static char *xread(const char *path)
{
	FILE *f = fopen(path, "r");
	char *buf;
	size_t cap = 4096, len = 0, n;

	if (!f)
		return NULL;
	buf = malloc(cap);
	if (!buf) { fclose(f); return NULL; }

	while ((n = fread(buf + len, 1, cap - len - 1, f)) > 0) {
		len += n;
		if (len + 1 >= cap) {
			char *nb = realloc(buf, cap *= 2);

			if (!nb) { free(buf); fclose(f); return NULL; }
			buf = nb;
		}
	}
	if (ferror(f)) { free(buf); fclose(f); return NULL; }
	fclose(f);
	buf[len] = '\0';
	while (len && isspace((unsigned char)buf[len - 1]))
		buf[--len] = '\0';
	return buf;
}

/* same, but indent every line */
static void xcat_lines(const char *path)
{
	char *s = xread(path), *p, *nl;

	if (!s)
		return;
	for (p = s; p && *p; p = nl ? nl + 1 : NULL) {
		nl = strchr(p, '\n');
		if (nl)
			*nl = '\0';
		printf("  %s\n", p);
	}
	free(s);
}

static int xwrite(const char *path, const char *val)
{
	FILE *f = fopen(path, "w");

	if (!f)
		return -1;
	if (fprintf(f, "%s\n", val) < 0 || fclose(f) != 0)
		return -1;
	return 0;
}

/* "key: value" lookup inside a multi-line buffer, returns value or NULL */
static const char *kv(const char *buf, const char *key, char *out, size_t n)
{
	size_t klen = strlen(key);
	const char *p = buf;

	if (!buf)
		return NULL;

	for (; p && *p; ) {
		const char *eol = strchr(p, '\n');
		size_t len = eol ? (size_t)(eol - p) : strlen(p);
		const char *colon = memchr(p, ':', len);

		if (colon) {
			size_t kl = (size_t)(colon - p);

			if (kl == klen && strncmp(p, key, klen) == 0) {
				const char *v = colon + 1;
				size_t vl;

				while (*v == ' ' || *v == '\t')
					v++;
				vl = (size_t)((p + len) - v);
				if (vl >= n)
					vl = n - 1;
				memcpy(out, v, vl);
				out[vl] = '\0';
				return out;
			}
		}
		p = eol ? eol + 1 : NULL;
	}
	return NULL;
}

/* ---------------------------------------------------------------- lookup */
/* find /sys/class/hwmon/hwmonN whose name == radxa_svc_glink; caller frees */
static char *find_hwmon(void)
{
	DIR *d = opendir(HWMON_GLOB);
	struct dirent *de;
	char *res = NULL;

	if (!d)
		return NULL;
	while ((de = readdir(d))) {
		char p[512], *name;

		if (strncmp(de->d_name, "hwmon", 5) != 0)
			continue;
		snprintf(p, sizeof(p), HWMON_GLOB "/%s/name", de->d_name);
		name = xread(p);
		if (!name)
			continue;
		if (strcmp(name, HW_NAME) == 0) {
			char *q = malloc(512);

			if (q)
				snprintf(q, 512, HWMON_GLOB "/%s", de->d_name);
			res = q;
		}
		free(name);
		if (res)
			break;
	}
	closedir(d);
	return res;
}

static void hint_exit(void)
{
	fprintf(stderr,
"%s%sx%s fan device (%s) not found.\n\n"
"The Q8B fan is driven by the Radxa SVC firmware on the ADSP and Linux\n"
"only sees it while that service is alive. Check:\n\n"
"  1. BIOS: Radxa Platform Configuration -> Hypervisor Settings must be\n"
"     %sAuto%s (or Disabled/Close). With %sEnable%s the hypervisor takes over the\n"
"     ADSP and the service never shows up.\n"
"  2. Is the service up?\n"
"       dmesg | grep -i radxa_svc\n"
"       lsmod | grep radxa_svc_glink\n"
"     A crashed service comes back with a plain reboot.\n"
"  3. Make sure the pmc8280c-pwm node is %sdisabled%s in the device tree\n"
"     (\"ls /sys/class/pwm/\" must be empty), otherwise leds-qcom-lpg fights\n"
"     the firmware over the same PWM and the fan sticks at 100%%.\n\n",
		C_BLD, C_RED, C_OFF, HW_NAME, C_BLD, C_OFF, C_BLD, C_OFF, C_BLD, C_OFF);
	exit(1);
}

static char *hwmon_or_die(void)
{
	char *h = find_hwmon();

	if (!h)
		hint_exit();
	return h;
}

static const char *mode_name(const char *v)
{
	if (!v)             return "unknown";
	if (!strcmp(v, "0")) return "full speed (forced)";
	if (!strcmp(v, "1")) return "manual";
	if (!strcmp(v, "2")) return "automatic (firmware thermal control)";
	return "unknown";
}

static void need_root(const char *what)
{
	if (geteuid() != 0)
		die("'%s' needs root (use sudo)", what);
}

static int duty_pct(int v)
{
	return (v * 100 + 127) / 255;
}

/* --------------------------------------------------------------- thermals */
static const char *sensor_want[] = {
	"cluster0-thermal", "cluster1-thermal", "gpuss-0-thermal", "pm8280-1-thermal",
	"top-left-thermal", "top-right-thermal", "led-thermal", "vbat-thermal", NULL
};

/* find a thermal_zoneN whose type matches, return temp in milli-degrees */
static int find_thermal(const char *want, int *mdeg)
{
	DIR *d = opendir("/sys/class/thermal");
	struct dirent *de;
	int found = 0;

	if (!d)
		return 0;
	while (!found && (de = readdir(d))) {
		char p[512], *type, *t;

		if (strncmp(de->d_name, "thermal_zone", 12) != 0)
			continue;
		snprintf(p, sizeof(p), "/sys/class/thermal/%s/type", de->d_name);
		type = xread(p);
		if (!type)
			continue;
		if (strcmp(type, want) == 0) {
			snprintf(p, sizeof(p), "/sys/class/thermal/%s/temp", de->d_name);
			t = xread(p);
			if (t) {
				*mdeg = atoi(t);
				found = 1;
			}
			free(t);
		}
		free(type);
	}
	closedir(d);
	return found;
}

static void print_thermals(void)
{
	int i;

	for (i = 0; sensor_want[i]; i++) {
		int mdeg = 0;

		if (find_thermal(sensor_want[i], &mdeg))
			printf("  %-18s %d.%d C\n", sensor_want[i], mdeg / 1000,
			       (mdeg % 1000) / 100);
	}
}

/* --------------------------------------------------------------- commands */
static void cmd_status(void)
{
	char *h = hwmon_or_die();
	char p[512], *buf, tmp[128];
	int duty = -1, enable = -1;

	snprintf(p, sizeof(p), "%s/pwm1", h);
	buf = xread(p);
	if (buf) { duty = atoi(buf); free(buf); }
	snprintf(p, sizeof(p), "%s/pwm1_enable", h);
	buf = xread(p);
	if (buf) { enable = atoi(buf); free(buf); }

	hdr("fan");
	printf("  device       : %s\n", h);
	printf("  duty         : %d/255  (~%d%%)\n", duty, duty_pct(duty < 0 ? 0 : duty));
	snprintf(tmp, sizeof(tmp), "%d", enable);
	printf("  mode         : %d -> %s\n", enable, mode_name(tmp));

	buf = xread(PROF_DIR "/profile");
	printf("  profile      : %s\n", buf ? buf : "-");
	free(buf);

	buf = xread(DBG_DIR "/fan_state");
	if (buf) {
		char ver[128] = "", major[32], minor[32], cpu[32], gpu[32];
		char loop[32], fault[32], cd[32], td[32], ch[32], per[32];
		char *vb = xread(DBG_DIR "/version");

		if (vb) {
			const char *a = kv(vb, "major", major, sizeof(major));
			const char *b = kv(vb, "minor", minor, sizeof(minor));

			if (a && b)
				snprintf(ver, sizeof(ver), "%s.%s", a, b);
			free(vb);
		}
		kv(buf, "cpu_temp_c", cpu, sizeof(cpu));
		kv(buf, "gpu_temp_c", gpu, sizeof(gpu));
		kv(buf, "loop_count", loop, sizeof(loop));
		kv(buf, "fault_count", fault, sizeof(fault));
		kv(buf, "current_duty_ns", cd, sizeof(cd));
		kv(buf, "target_duty_ns", td, sizeof(td));
		kv(buf, "pwm_channel", ch, sizeof(ch));
		kv(buf, "pwm_period_ns", per, sizeof(per));

		printf("  firmware     : v%s  cpu %s C / gpu %s C  loop %s  faults %s\n",
		       ver[0] ? ver : "?", cpu, gpu, loop, fault);
		printf("  duty now/tgt : %s ns / %s ns   (ch %s, period %s ns)\n",
		       cd, td, ch, per);

		if (kv(buf, "emergency", tmp, sizeof(tmp)) && !strcmp(tmp, "1"))
			warnx_("firmware emergency cooling active!");
		free(buf);
	}

	hdr("kernel thermal sensors");
	print_thermals();
	free(h);
}

static void cmd_auto(void)
{
	char p[512], *h = hwmon_or_die();

	need_root("auto");
	snprintf(p, sizeof(p), "%s/pwm1_enable", h);
	if (xwrite(p, "2") != 0)
		die("failed to switch to auto mode: %s", strerror(errno));
	ok("mode : automatic (firmware thermal control)");
	snprintf(p, sizeof(p), "%s/pwm1", h);
	{
		char *v = xread(p);

		ok("duty : %s/255  (the firmware moves it with the temperature)", v ? v : "?");
		free(v);
	}
	free(h);
}

static void cmd_full(void)
{
	char p[512], *h = hwmon_or_die();

	need_root("full");
	snprintf(p, sizeof(p), "%s/pwm1_enable", h);
	if (xwrite(p, "0") != 0)
		die("failed to force full speed: %s", strerror(errno));
	snprintf(p, sizeof(p), "%s/pwm1", h);
	{
		char *v = xread(p);

		ok("mode : full speed (forced)  duty=%s/255", v ? v : "?");
		free(v);
	}
	warnx_("restore with: %s auto", prog);
	free(h);
}

static void cmd_manual(const char *pct_arg)
{
	char p[512], *h = hwmon_or_die();
	int pct = -1, val;
	char *v;

	need_root("manual");
	snprintf(p, sizeof(p), "%s/pwm1_enable", h);
	if (xwrite(p, "1") != 0)
		die("failed to switch to manual mode: %s", strerror(errno));

	if (pct_arg) {
		const char *s = pct_arg;

		for (; *s; s++)
			if (!isdigit((unsigned char)*s))
				die("expected a percentage 0..100");
		pct = atoi(pct_arg);
		if (pct > 100)
			die("expected a percentage 0..100");
		val = (pct * 255 + 50) / 100;
		if (pct > 0 && val == 0)
			val = 1;
		snprintf(p, sizeof(p), "%s/pwm1", h);
		{
			char num[8];

			snprintf(num, sizeof(num), "%d", val);
			if (xwrite(p, num) != 0)
				die("failed to write pwm1: %s", strerror(errno));
		}
		if (pct == 0)
			warnx_("0%% can stop the fan completely - '%s auto' gives control back", prog);
	}

	snprintf(p, sizeof(p), "%s/pwm1", h);
	v = xread(p);
	ok("mode : manual  duty=%s/255 (~%d%%)", v ? v : "?", duty_pct(v ? atoi(v) : 0));
	free(v);
	if (!pct_arg)
		ok("froze the current speed");
	warnx_("manual mode stays until reboot or '%s auto'", prog);
	free(h);
}

/* "choices" is a newline separated list of profile names */
static int choices_has(const char *choices, const char *want)
{
	size_t wlen = strlen(want);
	const char *p = choices;

	while (p && *p) {
		size_t len = strcspn(p, "\n");

		if (len == wlen && !strncmp(p, want, wlen))
			return 1;
		p += len;
		if (*p)
			p++;
	}
	return 0;
}

static void cmd_profile(const char *want)
{
	char *cur, *choices;

	if (want == NULL) {
		cur = xread(PROF_DIR "/profile");
		choices = xread(PROF_DIR "/choices");
		if (!choices)
			die("no platform-profile device (firmware too old?)");
		printf("profile : %s\nchoices : %s\n", cur ? cur : "-", choices);
		free(cur);
		free(choices);
		return;
	}

	need_root("profile");
	choices = xread(PROF_DIR "/choices");
	if (!choices)
		die("no platform-profile device (firmware too old?)");

	if (!choices_has(choices, want))
		die("unknown profile '%s' (choices: %s)", want, choices);
	free(choices);

	if (xwrite(PROF_DIR "/profile", want) != 0)
		die("failed to set profile: %s", strerror(errno));
	{
		char *now = xread(PROF_DIR "/profile");

		ok("profile: %s   (the fan curve itself lives in the firmware)", now ? now : want);
		free(now);
	}
}

static void cmd_info(void)
{
	hdr("firmware"); xcat_lines(DBG_DIR "/version");
	hdr("pwm");      xcat_lines(DBG_DIR "/pwm_info");
	                 xcat_lines(DBG_DIR "/pwm_state");
	hdr("link");     xcat_lines(DBG_DIR "/stats");
}

static void cmd_temps(const char *idx_arg)
{
	char *count = xread(DBG_DIR "/tsens_count");
	int n = -1;

	if (count) {
		char v[32];

		if (kv(count, "num_sensors", v, sizeof(v)))
			n = atoi(v);
		free(count);
	}

	if (!idx_arg) {
		if (n < 0)
			die("no firmware tsens interface (service down?)");
		printf("firmware tsens sensors: %d\n", n);
		printf("usage: %s temps <0..%d>     # one sensor per call\n", prog, n - 1);
		xcat_lines(DBG_DIR "/tsens_max");
		return;
	}

	{
		const char *s = idx_arg;
		int idx;

		for (; *s; s++)
			if (!isdigit((unsigned char)*s))
				die("expected a sensor index");
		idx = atoi(idx_arg);
		if (n >= 0 && idx >= n)
			die("sensor index out of range (0..%d)", n - 1);
		if (xwrite(DBG_DIR "/tsens_temp", idx_arg) != 0)
			die("failed to select sensor %d: %s", idx, strerror(errno));
	}
	{
		char *out = xread(DBG_DIR "/tsens_temp");
		char t[32] = "?", c[32] = "?", ch[32] = "?";

		if (out) {
			kv(out, "temp_c", t, sizeof(t));
			kv(out, "controller", c, sizeof(c));
			kv(out, "channel", ch, sizeof(ch));
			free(out);
		}
		printf("sensor %-3s %s C   (controller %s, channel %s)\n", idx_arg, t, c, ch);
	}
}

static void cmd_log(void)
{
	xcat_lines(DBG_DIR "/log");
}

static void cmd_watch(const char *secs_arg)
{
	double secs = 2.0;
	char *h = hwmon_or_die();
	char p[512];

	if (secs_arg) {
		const char *s = secs_arg;

		for (; *s; s++)
			if (!isdigit((unsigned char)*s) && *s != '.')
				die("usage: %s watch [seconds]", prog);
		secs = atof(secs_arg);
		if (secs <= 0)
			secs = 2.0;
	}

	printf("%s  %-8s %-6s %-4s %-10s %s%s\n", C_BLD, "time", "duty", "pct",
	       "mode", "cluster0", C_OFF);

	for (;;) {
		char *duty, *en;
		int md = 0;
		struct timespec ts;

		snprintf(p, sizeof(p), "%s/pwm1", h);
		duty = xread(p);                       /* 1 rpmsg request */
		snprintf(p, sizeof(p), "%s/pwm1_enable", h);
		en = xread(p);                         /* 1 rpmsg request */

		{	/* temperature from the kernel, costs no ADSP round trip */
			char buf[32], pctbuf[8] = "?";
			time_t now = time(NULL);
			struct tm tm;

			if (duty)
				snprintf(pctbuf, sizeof(pctbuf), "%d%%", duty_pct(atoi(duty)));
			localtime_r(&now, &tm);
			strftime(buf, sizeof(buf), "%T", &tm);

			printf("  %-8s %-6s %-4s %-10s ", buf, duty ? duty : "?",
			       pctbuf, en ? en : "?");
			if (find_thermal("cluster0-thermal", &md))
				printf("%d.%d C", md / 1000, (md % 1000) / 100);
			else
				printf("-");
			printf("\n");
		}

		free(duty);
		free(en);

		ts.tv_sec = (time_t)secs;
		ts.tv_nsec = (long)((secs - (double)ts.tv_sec) * 1e9);
		nanosleep(&ts, NULL);
	}
}

static void usage(void)
{
	printf(
"%s%s %s - fan control for the Radxa Dragon Q8B\n"
"\n"
"Usage: sudo %s [command] [args]\n"
"\n"
"  status                    fan duty/mode/profile + temperatures   (default)\n"
"  auto                      hand control back to the firmware          [root]\n"
"  full                      force full speed                           [root]\n"
"  manual [0-100]            manual speed, no value = freeze current    [root]\n"
"  profile [quiet|performance]   get/set the platform profile           [root]\n"
"  watch [seconds]           live duty / mode / cluster0 temperature\n"
"  info                      firmware version, PWM info, link stats\n"
"  temps [sensor]            firmware tsens sensors (one at a time)\n"
"  log                       firmware log\n"
"  help | --version\n"
"\n"
"Notes\n"
"  * The fan is driven by Radxa's SVC firmware on the ADSP, not by Linux;\n"
"    the real fan curve therefore lives in the firmware. 'quiet' and\n"
"    'performance' select between two curves.\n"
"  * BIOS -> Radxa Platform Configuration -> Hypervisor Settings must be\n"
"    Auto (or Disabled) - with \"Enable\" the service does not come up.\n"
"  * Never enable the pmc8280c-pwm node in the device tree: leds-qcom-lpg\n"
"    would take the same PWM the firmware drives -> fan stuck at 100%%.\n"
"  * Every value above is fetched over rpmsg from the ADSP, so don't poll\n"
"    this tool in a tight loop.\n",
	C_BLD, prog, VERSION, prog);
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "status";

	col_init();
	if (argc > 0 && argv[0] && strrchr(argv[0], '/'))
		prog = strrchr(argv[0], '/') + 1;

	if (!strcmp(cmd, "status") || !strcmp(cmd, "st")) {
		cmd_status();
	} else if (!strcmp(cmd, "auto")) {
		cmd_auto();
	} else if (!strcmp(cmd, "full")) {
		cmd_full();
	} else if (!strcmp(cmd, "manual") || !strcmp(cmd, "man")) {
		cmd_manual(argc > 2 ? argv[2] : NULL);
	} else if (!strcmp(cmd, "profile") || !strcmp(cmd, "prof")) {
		cmd_profile(argc > 2 ? argv[2] : NULL);
	} else if (!strcmp(cmd, "watch") || !strcmp(cmd, "w")) {
		cmd_watch(argc > 2 ? argv[2] : NULL);
	} else if (!strcmp(cmd, "info")) {
		cmd_info();
	} else if (!strcmp(cmd, "temps") || !strcmp(cmd, "temp")) {
		cmd_temps(argc > 2 ? argv[2] : NULL);
	} else if (!strcmp(cmd, "log")) {
		cmd_log();
	} else if (!strcmp(cmd, "help") || !strcmp(cmd, "-h") || !strcmp(cmd, "--help")) {
		usage();
	} else if (!strcmp(cmd, "-V") || !strcmp(cmd, "--version")) {
		printf("%s\n", VERSION);
	} else {
		usage();
		die("unknown command: %s", cmd);
	}
	return 0;
}
